# Backend Battle 2026 - Fraud Detection via Vector Search

[![Zig](https://img.shields.io/badge/Zig-0.16.0-F7A41D?style=for-the-badge&logo=zig&logoColor=white)](https://ziglang.org/)
[![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?style=for-the-badge&logo=docker&logoColor=white)](https://www.docker.com/)
[![HAProxy](https://img.shields.io/badge/HAProxy-3.3-1D1D24?style=for-the-badge&logo=haproxy&logoColor=white)](https://www.haproxy.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](LICENSE)

**Pure. Blazingly Fast. Modern Zig.**

A high-performance fraud detection API built with **Zig 0.16.0**. This project
implements a k-Nearest Neighbors (k-NN) search using a native Zig SIMD engine to
decide on transaction approval based on a reference dataset.

## Architecture & Documentation

For a detailed breakdown of the request flow, module dependencies, and domain
boundaries, please see the [Architecture Documentation](docs/architecture.md).

## Prerequisites

- **Zig 0.16.0**
- **curl** (for manual testing)

## Building

To compile the project and generate the executable:

```bash
zig build
```

The resulting binary will be located at `zig-out/bin/rinha`.

## Testing

### Automated Tests

Run the project unit tests (includes SIMD kernel and normalization tests):

```bash
zig build test
```

### Code Quality

To enforce consistent formatting across Zig and JSON/Markdown files:

```bash
zig build fmt
```

### Data Preparation

If you need to regenerate the binary dataset (`references.bin` and `labels.bin`)
from the JSON resources:

```bash
# Note: This requires the references JSON in resources/
zig build prep
```

## Running the Server

Start the API server on the default port (9999):

```bash
zig build run
```

Or run the binary directly:

```bash
./zig-out/bin/rinha
```

The server will automatically map `references.bin` and `labels.bin` from the
current working directory.

## API Endpoints

### `GET /ready`

Used by the load balancer/orchestrator to check if the API is ready to receive
traffic.

**Response:** `200 OK` (Body: `OK`)

### `POST /fraud-score`

Receives a raw transaction payload, normalizes it into a vector, performs a k-NN
search, and returns a fraud decision.

#### Request Body (JSON)

```json
{
  "id": "tx-12345",
  "transaction": {
    "amount": 150.0,
    "installments": 1,
    "requested_at": "2026-03-11T18:45:53Z"
  },
  "customer": {
    "avg_amount": 100.0,
    "tx_count_24h": 5,
    "known_merchants": ["MERC-001", "MERC-002"]
  },
  "merchant": {
    "id": "MERC-003",
    "mcc": "5411",
    "avg_amount": 60.25
  },
  "terminal": {
    "is_online": true,
    "card_present": false,
    "km_from_home": 12.5
  },
  "last_transaction": {
    "timestamp": "2026-03-11T15:30:00Z",
    "km_from_current": 5.0
  }
}
```

_Note: `last_transaction` can be `null`._

#### Response Body (JSON)

```json
{
  "approved": true,
  "fraud_score": 0.2
}
```

## Manual Verification Examples

### 1. Ready Check

```bash
curl -i http://localhost:9999/ready
```

### 2. Legitimate Transaction

```bash
curl -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d '{
    "id": "tx-legit",
    "transaction": { "amount": 41.12, "installments": 2, "requested_at": "2026-03-11T18:45:53Z" },
    "customer": { "avg_amount": 82.24, "tx_count_24h": 3, "known_merchants": ["MERC-016"] },
    "merchant": { "id": "MERC-016", "mcc": "5411", "avg_amount": 60.25 },
    "terminal": { "is_online": false, "card_present": true, "km_from_home": 29.23 },
    "last_transaction": null
  }'
```

### 3. Suspicious Transaction (High Amount & Distance)

```bash
curl -X POST http://localhost:9999/fraud-score \
  -H "Content-Type: application/json" \
  -d '{
    "id": "tx-fraud",
    "transaction": { "amount": 9500.00, "installments": 10, "requested_at": "2026-03-14T05:15:12Z" },
    "customer": { "avg_amount": 80.00, "tx_count_24h": 20, "known_merchants": [] },
    "merchant": { "id": "MERC-068", "mcc": "7802", "avg_amount": 50.00 },
    "terminal": { "is_online": false, "card_present": true, "km_from_home": 950.00 },
    "last_transaction": null
  }'
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file
for details.
