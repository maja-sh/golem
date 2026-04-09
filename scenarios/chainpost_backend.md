# ChainPost Backend: Blockchain Microblogging Platform

**Difficulty:** Very Hard
**Expected steps:** 200-400
**Recommended max_steps:** 500
**Language:** Rust

## Goal

Build the backend for a decentralized microblogging platform powered by a proof-of-work blockchain. Every action (post, user registration, follow, etc.) is a signed transaction included in mined blocks. There is no central authority — any node can join the P2P network and participate.

This is a fresh build of a project previously called "cryptogram." The architecture has been redesigned with transactions-in-blocks, Heed-only indexing, and a proper sync protocol.

### Environment

You have root access to a Ubuntu 24.04 container. Rust is NOT pre-installed — install it with `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y` as the first build step. You'll also need build-essential and pkg-config for native deps.

Put everything in `/home/agent/chainpost/`.

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                 Node Binary                  │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │   API    │  │   P2P    │  │   Miner   │  │
│  │  (axum)  │  │ (libp2p) │  │  (tokio)  │  │
│  └────┬─────┘  └────┬─────┘  └─────┬─────┘  │
│       │              │              │         │
│  ┌────▼──────────────▼──────────────▼──────┐  │
│  │              Blockchain                 │  │
│  │  Chain + Mempool + Validation           │  │
│  └────────────────┬────────────────────────┘  │
│                   │                           │
│  ┌────────────────▼────────────────────────┐  │
│  │              Storage (Heed/LMDB)        │  │
│  │  blocks | tx_index | users | follows    │  │
│  └─────────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

---

## Data Model

### Block

```rust
struct Block {
    index: u64,
    timestamp: u64,
    nonce: u64,
    prev_hash: [u8; 32],    // SHA-256
    hash: [u8; 32],          // SHA-256
    transactions: Vec<Transaction>,
}
```

### Transaction

```rust
struct Transaction {
    hash: [u8; 32],           // SHA-256 of (tx_type + data + timestamp + public_key)
    tx_type: TxType,
    data: TxData,
    public_key: [u8; 32],    // Ed25519
    signature: [u8; 64],     // Ed25519
    timestamp: u64,
}

enum TxType {
    UserRegister,
    UserUpdate,
    Post,
    Follow,
    Unfollow,
}

enum TxData {
    UserRegister { username: String, display_name: String, bio: String },
    UserUpdate { display_name: Option<String>, bio: Option<String> },
    Post { body: String, reply_to: Option<[u8; 32]> },  // reply_to = tx hash
    Follow { target: [u8; 32] },      // target public key
    Unfollow { target: [u8; 32] },
}
```

### Validation Rules

- **UserRegister**: username must be unique, username max 30 chars, display_name max 50, bio max 300
- **UserUpdate**: public_key must be registered
- **Post**: public_key must be registered, body max 300 chars, reply_to must exist if set
- **Follow**: both public keys must be registered, can't follow self, can't double-follow
- **Unfollow**: must currently be following the target
- **All transactions**: valid Ed25519 signature over (tx_type + data + timestamp)
- **Blocks**: valid PoW (configurable difficulty), valid prev_hash chain, all txs valid

### Proof of Work

- Difficulty: configurable number of leading zero bits in SHA-256 hash
- Default difficulty: 16 bits (adjustable)
- Mining input: block header (index + timestamp + prev_hash + merkle_root_of_txs + nonce)
- Nonce incremented until hash meets difficulty

---

## Storage Design (Heed/LMDB)

Single LMDB environment with multiple named databases. **No data duplication** — indexes store pointers (block_index, tx_position) not copies.

| Database | Key | Value | Purpose |
|----------|-----|-------|---------|
| `blocks` | u64 (index) | Block (bincode) | Primary block storage |
| `block_hashes` | [u8; 32] (hash) | u64 (index) | Hash → block lookup |
| `tx_index` | [u8; 32] (tx hash) | (u64, u16) | Tx hash → (block_index, position) |
| `usernames` | String | [u8; 32] (pubkey) | Username → pubkey |
| `profiles` | [u8; 32] (pubkey) | UserProfile (bincode) | Latest profile state |
| `user_posts` | [u8; 32] (pubkey) | Vec<[u8; 32]> (tx hashes) | User's post hashes (ordered) |
| `following` | [u8; 32] (pubkey) | Vec<[u8; 32]> (pubkeys) | Who this user follows |
| `followers` | [u8; 32] (pubkey) | Vec<[u8; 32]> (pubkeys) | Who follows this user |

When a block is added, the indexer processes each transaction and updates the relevant databases.

---

## P2P Networking (libp2p)

### Transport
- TCP + noise encryption + yamux multiplexing
- mDNS for local peer discovery
- Configurable listen port (default 4001)

### Protocols
1. **Gossipsub** — broadcast new blocks and new transactions
   - Topic: `chainpost/blocks/1.0.0` — new mined blocks
   - Topic: `chainpost/txs/1.0.0` — new transactions (pre-mining)

2. **Request-Response** — chain sync
   - `ChainLength` request → returns current chain height
   - `GetBlocks { from: u64, to: u64 }` → returns blocks in range
   - Used when a new peer joins to catch up

### Sync Protocol
1. On peer connect, request their chain length
2. If theirs is longer, request missing blocks in batches of 50
3. Validate each block before adding
4. If fork detected (different hash at same height), prefer longer chain

### Message Types
```rust
enum GossipMessage {
    NewBlock(Block),
    NewTransaction(Transaction),
}

enum SyncRequest {
    ChainLength,
    GetBlocks { from: u64, to: u64 },
}

enum SyncResponse {
    ChainLength(u64),
    Blocks(Vec<Block>),
}
```

---

## API (axum)

REST API for frontends. Any client can build against this.

### Endpoints

**Transactions:**
- `POST /api/transactions` — Submit a signed transaction. Goes to mempool.
  - Body: `{ tx_type, data, public_key, signature, timestamp }`
  - Returns: `{ hash }` or validation error

**Users:**
- `GET /api/users/:username` — Get user profile by username
- `GET /api/users/key/:pubkey` — Get user profile by public key
- `GET /api/users/:username/posts?offset=0&limit=20` — User's posts (paginated)
- `GET /api/users/:username/followers?offset=0&limit=20` — User's followers
- `GET /api/users/:username/following?offset=0&limit=20` — Who user follows
- `GET /api/users/search?q=prefix&limit=10` — Search users by username prefix

**Posts:**
- `GET /api/posts/:hash` — Get post by tx hash (includes reply count, parent if reply)
- `GET /api/posts/:hash/replies?offset=0&limit=20` — Get replies to a post

**Feed:**
- `GET /api/feed/:pubkey?offset=0&limit=20` — Chronological feed from followed users
- `GET /api/feed/:pubkey/discover?offset=0&limit=20` — Algorithmic "discover" feed

**Node:**
- `GET /api/status` — Chain height, peer count, mempool size
- `GET /api/blocks/:index` — Get block by index
- `GET /api/blocks/latest` — Get latest block

### Discover Feed Algorithm

Score = recency_score + engagement_score + social_score

- **recency_score**: exponential decay from post timestamp (newer = higher)
- **engagement_score**: reply_count * 2 (posts with discussion rank higher)
- **social_score**: if the post's author is followed by people you follow (2nd degree), boost score

This requires no ML — just graph traversal and scoring at query time.

---

## Mining

- Runs in a separate tokio task
- Watches the mempool for pending transactions
- When mempool has transactions AND enough time has passed since last block (min 5 seconds):
  - Collect up to 50 transactions from mempool
  - Build block header with merkle root
  - Mine (find nonce) in a blocking thread (tokio::spawn_blocking)
  - On success, add block to chain and broadcast via gossipsub
- Mining can be paused/resumed via API or CLI flag

---

## Project Structure

```
chainpost/
├── Cargo.toml
├── src/
│   ├── main.rs              # CLI args, node startup
│   ├── blockchain/
│   │   ├── mod.rs
│   │   ├── block.rs          # Block struct, hashing, PoW
│   │   ├── transaction.rs    # Transaction types, signing, validation
│   │   ├── chain.rs          # Chain state, block validation, fork handling
│   │   ├── mempool.rs        # Transaction pool
│   │   └── store.rs          # Heed storage + indexing
│   ├── p2p/
│   │   ├── mod.rs
│   │   ├── behaviour.rs      # libp2p behaviour (gossipsub + mdns + request-response)
│   │   ├── service.rs        # P2P event loop
│   │   └── sync.rs           # Chain sync protocol
│   ├── api/
│   │   ├── mod.rs
│   │   ├── server.rs         # axum router setup
│   │   ├── handlers.rs       # Route handlers
│   │   └── models.rs         # API request/response types
│   └── crypto.rs             # Ed25519 helpers, hashing
├── tests/
│   ├── blockchain_tests.rs   # Chain validation, PoW, transactions
│   ├── storage_tests.rs      # Store read/write/index
│   └── p2p_tests.rs          # Network message handling
└── README.md
```

---

## Code Quality Requirements

This codebase must be production-quality. The operator will maintain it.

### Readability
- **Clear naming**: function and variable names should read like English. `validate_transaction_signature` not `val_tx_sig`. `is_username_taken` not `check_un`.
- **Small functions**: each function does one thing. If a function is over 40 lines, split it.
- **Module-level docs**: every module (`mod.rs`, top of each file) has a doc comment explaining what it does and how it fits into the architecture.
- **Public API docs**: every pub function has a `///` doc comment.
- **No magic numbers**: constants have names. `const MAX_POST_LENGTH: usize = 300;`
- **Error handling**: use `thiserror` for typed errors. No `.unwrap()` in non-test code. Every error case should be handled or propagated with `?` and a meaningful error type.
- **No dead code**: don't leave commented-out code or unused functions.

### Testing Strategy

Tests are critical. Write them as you go, not as an afterthought.

**Unit tests** (in each module):
- `block.rs`: block creation, hashing, PoW validation, invalid block rejection
- `transaction.rs`: all tx types, signing, signature verification, validation rules (invalid username, too-long post, double registration, etc.)
- `chain.rs`: genesis, adding valid blocks, rejecting invalid blocks, fork handling
- `mempool.rs`: add/remove txs, duplicate rejection, ordering
- `store.rs`: write/read blocks, index queries, user lookup, follow graph, pagination

**Integration tests** (`tests/` directory):
- `test_blockchain.rs`: full flow — create chain, build transactions, mine blocks, query state
- `test_api.rs`: spin up axum server, test every endpoint with real HTTP requests (use `reqwest`). Cover happy paths AND error cases (invalid tx, missing user, etc.)
- `test_e2e.rs`: full end-to-end test:
  1. Start a node (chain + mempool + API, no P2P needed)
  2. Register two users via API
  3. User A follows User B
  4. User B creates a post
  5. Mine a block (trigger mining directly, don't wait)
  6. Verify User A's feed contains User B's post
  7. User A replies to User B's post
  8. Mine again
  9. Verify the reply appears on the post detail endpoint
  10. Verify follower/following counts are correct
  11. User A unfollows User B
  12. Mine again
  13. Verify feed no longer contains User B's posts

**P2P tests** (`test_p2p.rs`):
- Start two nodes on different ports
- Submit a transaction on node 1
- Mine on node 1
- Verify node 2 received the block via gossipsub
- Start a third node, verify it syncs the full chain

Run `cargo test` at the end of each phase. All tests must pass before moving to the next phase.

---

## Build Phases

### Phase 1: Core Blockchain
- [ ] Set up Cargo project with dependencies (including thiserror, anyhow for errors)
- [ ] Define error types for blockchain, storage, API, P2P
- [ ] Implement Block and Transaction structs with serialization
- [ ] Implement SHA-256 hashing and PoW mining
- [ ] Implement Ed25519 signing and verification
- [ ] Implement transaction validation rules (all tx types)
- [ ] Implement Chain (add block, validate chain, genesis)
- [ ] Write unit tests for block, transaction, and chain
- [ ] Run `cargo test` — all must pass

### Phase 2: Storage
- [ ] Set up Heed with multiple databases
- [ ] Implement block storage and retrieval
- [ ] Implement transaction indexing
- [ ] Implement user index (username → pubkey, profiles)
- [ ] Implement follow graph (following/followers)
- [ ] Implement post index (user → posts, with pagination)
- [ ] Write unit tests for all storage operations
- [ ] Run `cargo test` — all must pass

### Phase 3: Mempool & Mining
- [ ] Implement mempool (add, drain, duplicate rejection)
- [ ] Implement mining task (separate tokio task with spawn_blocking for PoW)
- [ ] Connect mining to mempool and chain
- [ ] Write unit tests for mempool
- [ ] Run `cargo test` — all must pass

### Phase 4: API
- [ ] Set up axum server with CORS
- [ ] Implement transaction submission endpoint
- [ ] Implement user endpoints (profile, search)
- [ ] Implement post endpoints (detail, replies)
- [ ] Implement feed endpoints (chronological + discover)
- [ ] Implement node status endpoint
- [ ] Write integration tests: spin up server, test every endpoint with reqwest
- [ ] Run `cargo test` — all must pass

### Phase 5: P2P Networking
- [ ] Set up libp2p with gossipsub + mDNS + request-response
- [ ] Implement block and transaction broadcasting
- [ ] Implement chain sync protocol
- [ ] Handle peer discovery and connection
- [ ] Write P2P tests (message serialization, two-node sync)
- [ ] Run `cargo test` — all must pass

### Phase 6: End-to-End Tests
- [ ] Write E2E test: full user flow (register → follow → post → feed → reply → unfollow)
- [ ] Write E2E test: multi-node sync
- [ ] Write E2E test: chain sync on late-joining node
- [ ] Run full `cargo test` — everything must pass
- [ ] Run `cargo clippy` — fix all warnings
- [ ] Run `cargo fmt` — format all code
- [ ] Write README with architecture, usage, and test instructions

---

## Key Dependencies (Cargo.toml)

```toml
[dependencies]
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
bincode = "1"
sha2 = "0.10"
ed25519-dalek = { version = "2", features = ["serde"] }
rand = "0.8"
heed = "0.20"
libp2p = { version = "0.54", features = ["tokio", "gossipsub", "mdns", "noise", "tcp", "yamux", "request-response", "macros"] }
axum = "0.7"
tower-http = { version = "0.5", features = ["cors"] }
clap = { version = "4", features = ["derive"] }
hex = "0.4"
tracing = "0.1"
tracing-subscriber = "0.3"
```

---

## Notes

This is a from-scratch implementation. The previous attempt ("cryptogram") used:
- One block per action (we use transactions-in-blocks instead)
- Heed + SQLite for indexing (we use Heed-only with pointer indexes)
- No chain sync protocol (we implement proper sync)
- Warp for API (we use axum)
- Single-threaded mining that blocked P2P (we use spawn_blocking)
