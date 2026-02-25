FROM python:3.13-slim

WORKDIR /app

# Install deps first (cached layer)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY . .

# Never run as root
RUN useradd -m agentuser
USER agentuser

CMD ["python", "main.py"]
