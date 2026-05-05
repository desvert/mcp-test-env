#!/usr/bin/env python3
"""
hvac_server.py - Modbus TCP server simulating a simple HVAC controller.

Register map:
  Coils (read/write, 1-bit):
    0x0001  Fan enable        (0=off, 1=on)
    0x0002  Cooling enable    (0=off, 1=on)
    0x0003  Heating enable    (0=off, 1=on)
    0x0004  Alarm reset       (write 1 to clear alarms; auto-resets to 0)

  Discrete Inputs (read-only, 1-bit):
    0x0001  High-temp alarm   (set when zone temp > HIGH_TEMP_ALARM threshold)
    0x0002  Low-temp alarm    (set when zone temp < LOW_TEMP_ALARM threshold)
    0x0003  Filter alarm      (set when runtime_hours > FILTER_ALARM_HOURS)

  Holding Registers (read/write, 16-bit):
    0x0001  Setpoint          (tenths of degrees F, e.g. 720 = 72.0°F)
    0x0002  Fan speed %       (0-100)
    0x0003  High-temp alarm threshold (tenths of degrees F, default 850)
    0x0004  Low-temp alarm threshold  (tenths of degrees F, default 600)

  Input Registers (read-only, 16-bit):
    0x0001  Zone temperature  (tenths of degrees F, simulated drift)
    0x0002  Return air temp   (tenths of degrees F)
    0x0003  Supply air temp   (tenths of degrees F)
    0x0004  Runtime hours     (total compressor-on hours, wraps at 65535)

Usage:
  python hvac_server.py [--host HOST] [--port PORT] [--unit-id UNIT_ID]

Defaults:
  host=0.0.0.0  port=502  unit-id=1
"""

import argparse
import asyncio
import logging
import random
import signal
import sys
import time

from pymodbus.datastore import (
    ModbusSequentialDataBlock,
    ModbusServerContext,
    ModbusSlaveContext,
)
from pymodbus.server import StartAsyncTcpServer

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("hvac_server")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
FILTER_ALARM_HOURS = 500   # hours before filter alarm fires
UPDATE_INTERVAL    = 5.0   # seconds between simulated sensor updates

# Register index helpers (pymodbus uses 0-based addressing internally;
# the map above uses 1-based Modbus addresses, so subtract 1 for array index).
# Coil indices (0-based)
COIL_FAN       = 0
COIL_COOL      = 1
COIL_HEAT      = 2
COIL_ALARM_RST = 3

# Discrete input indices (0-based)
DI_HI_TEMP     = 0
DI_LO_TEMP     = 1
DI_FILTER      = 2

# Holding register indices (0-based)
HR_SETPOINT    = 0
HR_FAN_SPEED   = 1
HR_HI_THRESH   = 2
HR_LO_THRESH   = 3

# Input register indices (0-based)
IR_ZONE_TEMP   = 0
IR_RETURN_TEMP = 1
IR_SUPPLY_TEMP = 2
IR_RUNTIME_HRS = 3


def build_context() -> ModbusServerContext:
    """Build initial Modbus datastore with realistic HVAC defaults."""
    store = ModbusSlaveContext(
        co=ModbusSequentialDataBlock(0, [0] * 16),   # coils
        di=ModbusSequentialDataBlock(0, [0] * 16),   # discrete inputs
        hr=ModbusSequentialDataBlock(0, [
            720,   # setpoint:         72.0°F
            50,    # fan speed:        50%
            850,   # hi-temp thresh:   85.0°F
            600,   # lo-temp thresh:   60.0°F
            0, 0, 0, 0, 0, 0, 0, 0,   # padding
        ]),
        ir=ModbusSequentialDataBlock(0, [
            720,   # zone temp:        72.0°F
            680,   # return air:       68.0°F
            550,   # supply air:       55.0°F
            42,    # runtime hours
            0, 0, 0, 0, 0, 0, 0, 0,   # padding
        ]),
        zero_mode=True,
    )
    return ModbusServerContext(slaves=store, single=True)


async def simulate_sensors(context: ModbusServerContext, unit: int = 0x00) -> None:
    """
    Background task: update simulated sensor readings every UPDATE_INTERVAL seconds.

    Behaviour:
      - Zone temp drifts toward or away from setpoint depending on
        heating/cooling coil state, with small random noise.
      - Return air tracks zone temp with a slight lag.
      - Supply air reflects cooling (low) or heating (high) mode.
      - Runtime hours increments when cooling is active.
      - Alarms are set/cleared based on thresholds and alarm reset coil.
    """
    log.info("Sensor simulation started (update interval: %ss)", UPDATE_INTERVAL)

    while True:
        await asyncio.sleep(UPDATE_INTERVAL)

        store = context[unit]

        # Read current state
        coils = store.getValues(1, 0, 4)      # fc=1 = coils
        dis   = store.getValues(2, 0, 3)      # fc=2 = discrete inputs
        hrs   = store.getValues(3, 0, 4)      # fc=3 = holding registers
        irs   = store.getValues(4, 0, 4)      # fc=4 = input registers

        fan_on   = bool(coils[COIL_FAN])
        cool_on  = bool(coils[COIL_COOL])
        heat_on  = bool(coils[COIL_HEAT])
        alrm_rst = bool(coils[COIL_ALARM_RST])

        setpoint  = hrs[HR_SETPOINT]
        hi_thresh = hrs[HR_HI_THRESH]
        lo_thresh = hrs[HR_LO_THRESH]

        zone_temp    = irs[IR_ZONE_TEMP]
        return_temp  = irs[IR_RETURN_TEMP]
        supply_temp  = irs[IR_SUPPLY_TEMP]
        runtime_hrs  = irs[IR_RUNTIME_HRS]

        # ---- temperature drift logic ----
        noise = random.randint(-5, 5)          # tenths of a degree
        if cool_on and fan_on:
            drift = -10 + noise                # cooling pulls temp down
            new_supply = 550 + random.randint(-20, 20)
        elif heat_on and fan_on:
            drift = +10 + noise                # heating pushes temp up
            new_supply = 950 + random.randint(-20, 20)
        else:
            # passive: drift slowly toward a "building ambient" of 78°F (780)
            ambient = 780
            drift = (1 if zone_temp < ambient else -1) * 3 + noise
            new_supply = zone_temp + random.randint(-30, 30)

        new_zone   = max(400, min(1200, zone_temp + drift))
        new_return = max(400, min(1200, return_temp + (drift // 2) + random.randint(-3, 3)))
        new_supply = max(400, min(1200, new_supply))

        # ---- runtime hours ----
        # Increment fractionally; only store integer hours
        new_runtime = min(65535, runtime_hrs + (1 if cool_on else 0))

        # ---- alarm evaluation ----
        hi_alarm     = 1 if new_zone > hi_thresh else dis[DI_HI_TEMP]
        lo_alarm     = 1 if new_zone < lo_thresh else dis[DI_LO_TEMP]
        filter_alarm = 1 if new_runtime > FILTER_ALARM_HOURS else dis[DI_FILTER]

        if alrm_rst:
            hi_alarm     = 0
            lo_alarm      = 0
            # filter alarm intentionally NOT clearable by reset (requires maintenance)
            store.setValues(1, COIL_ALARM_RST, [0])   # auto-clear the reset coil
            log.info("Alarm reset triggered; latched alarms cleared")

        # ---- write back ----
        store.setValues(4, IR_ZONE_TEMP,   [new_zone])
        store.setValues(4, IR_RETURN_TEMP, [new_return])
        store.setValues(4, IR_SUPPLY_TEMP, [new_supply])
        store.setValues(4, IR_RUNTIME_HRS, [new_runtime])
        store.setValues(2, DI_HI_TEMP,     [hi_alarm, lo_alarm, filter_alarm])

        log.info(
            "zone=%.1f°F  return=%.1f°F  supply=%.1f°F  "
            "fan=%s  cool=%s  heat=%s  hi_alarm=%s  lo_alarm=%s  filter=%s  runtime=%sh",
            new_zone / 10, new_return / 10, new_supply / 10,
            "ON" if fan_on else "off",
            "ON" if cool_on else "off",
            "ON" if heat_on else "off",
            bool(hi_alarm), bool(lo_alarm), bool(filter_alarm),
            new_runtime,
        )


async def main(host: str, port: int, unit_id: int) -> None:
    context = build_context()

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _shutdown(sig, _frame):
        log.info("Received %s, shutting down...", sig.name)
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda s=sig: _shutdown(s, None))

    sim_task = asyncio.create_task(simulate_sensors(context, unit=0x00))

    log.info("Starting Modbus TCP server on %s:%s (unit ID %s)", host, port, unit_id)
    server = await StartAsyncTcpServer(
        context=context,
        address=(host, port),
    )

    await stop_event.wait()
    sim_task.cancel()
    try:
        await sim_task
    except asyncio.CancelledError:
        pass
    log.info("Server stopped.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Simulated HVAC Modbus TCP server")
    parser.add_argument("--host",    default="0.0.0.0",  help="Bind address")
    parser.add_argument("--port",    default=502, type=int, help="TCP port")
    parser.add_argument("--unit-id", default=1,  type=int, help="Modbus unit/slave ID")
    args = parser.parse_args()

    asyncio.run(main(args.host, args.port, args.unit_id))