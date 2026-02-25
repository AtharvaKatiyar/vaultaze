FROM python:3.13-slim

# Build context is the REPO ROOT (btc_vault/).
# Railway sets this via railway.toml → build.buildContextDir = ".".

WORKDIR /app

# Build tools required by starknet-py's native dependencies
# (crypto-cpp-py and poseidon-py compile C++ extensions via cmake/make)
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake make gcc g++ \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps first (layer-cached)
COPY agents/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy agent source code
COPY agents/ .

# Copy compiled contract ABIs that the client loads at runtime.
# Mirrors the path that config.py resolves: __file__/../../vault/target/dev/
RUN mkdir -p /vault/target/dev
COPY vault/target/dev/vault_BTCSecurityRouter.contract_class.json /vault/target/dev/
COPY vault/target/dev/vault_BTCVault.contract_class.json /vault/target/dev/
COPY vault/target/dev/vault_MockPragmaOracle.contract_class.json /vault/target/dev/

# Never run as root
RUN useradd -m agentuser && chown -R agentuser /app /vault
USER agentuser

CMD ["python", "main.py"]
