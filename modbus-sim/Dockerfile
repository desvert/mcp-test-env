FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir pymodbus==3.13.0

COPY src/hvac_server.py .

# Port 502 is the standard Modbus TCP port.
# Running as root is required to bind to port 502 inside the container;
# the container itself is isolated, so this is acceptable for a lab target.
EXPOSE 502/tcp

ENTRYPOINT ["python", "hvac_server.py"]
CMD ["--host", "0.0.0.0", "--port", "502", "--unit-id", "1"]