# ChainPost Frontend: Tauri + React Desktop Client

**Difficulty:** Hard
**Expected steps:** 150-300
**Recommended max_steps:** 400
**Language:** TypeScript/React + Rust (Tauri)

## Goal

Build a desktop client for the ChainPost blockchain microblogging platform using Tauri 2 + React. The client connects to a ChainPost node's API and provides a Twitter-like experience for creating accounts, posting, following users, and browsing feeds.

### Setup

Put everything in `/home/agent/chainpost-client/`. Rust and Node.js are already installed. Firefox is on DISPLAY=:99 for visual testing with the `browse` tool.

**IMPORTANT — Backend already exists:** The ChainPost backend node is already built at `/home/agent/chainpost/`. Before starting frontend work:
1. Explore the backend's API: read `/home/agent/chainpost/src/api/` to understand the available endpoints, request/response formats, and transaction signing requirements.
2. Start the backend node in the background: `cd /home/agent/chainpost && cargo run -- --api-port 3030 &`
3. Verify it's running: `curl http://localhost:3030/api/info`

The frontend connects to this running node. Do NOT rebuild or modify the backend.

**IMPORTANT — Research before building:** Tauri 2 is new and different from Tauri 1. Before writing any code:
1. Use `web_search` to find the official Tauri 2 project setup guide
2. Use `web_search` to find Tauri 2 command syntax (`#[tauri::command]` patterns, IPC, permissions)
3. Use `web_search` to find how to set up TailwindCSS with Vite (v4 changed significantly)

Do NOT guess at Tauri 2 or TailwindCSS APIs from memory. Search for current docs first.

**Project scaffold is pre-built:** A compiling Tauri 2 + React + TypeScript skeleton already exists at `/home/agent/chainpost-client/`. It includes:
- Vite + React + TypeScript frontend (`src/App.tsx`, `src/main.tsx`)
- Tauri 2 Rust backend (`src-tauri/src/lib.rs` with a sample `greet` command)
- All config files (`tauri.conf.json`, `Cargo.toml`, `vite.config.ts`, `tsconfig.json`)
- Dependencies listed in `package.json` (run `npm install` first)

Start by running `cd /home/agent/chainpost-client && npm install` then verify with `cd src-tauri && cargo check`. Do NOT re-scaffold or recreate the project structure — build on what's there.

**IMPORTANT — Non-interactive terminal:** You have NO interactive terminal. Do NOT use interactive scaffold tools (`npm create`, `npx tauri init`, `npx tailwindcss init`). Install packages with `npm install <pkg>` and create/edit config files manually.

---

## Architecture

```
┌─────────────────────────────────────────┐
│            Tauri 2 Desktop App          │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │         React Frontend             │  │
│  │  (TypeScript, TailwindCSS)         │  │
│  │                                    │  │
│  │  Auth → Feed → Profile → Post      │  │
│  └──────────────┬─────────────────────┘  │
│                 │                         │
│  ┌──────────────▼─────────────────────┐  │
│  │       Tauri Rust Backend           │  │
│  │  - Ed25519 key gen/signing         │  │
│  │  - BIP39 mnemonic gen/restore      │  │
│  │  - Secure key storage              │  │
│  └──────────────┬─────────────────────┘  │
│                 │                         │
│                 ▼                         │
│        ChainPost Node API               │
│        (localhost:3030)                   │
└─────────────────────────────────────────┘
```

---

## Screens

### 1. Auth — `/auth`
- **Register**: Username, display name, bio form → generates mnemonic → shows 12 words → submits UserRegister tx
- **Login**: Enter 12-word mnemonic → derives keypair → fetches profile from API → stores locally
- Clean, centered layout. Mnemonic display should be a 3x4 grid with numbered words.

### 2. Feed — `/` (requires auth)
- **Following tab**: Chronological posts from followed users via `GET /api/feed/:pubkey`
- **Discover tab**: Algorithmic feed via `GET /api/feed/:pubkey/discover`
- Each post shows: author avatar placeholder, display name, @username, relative timestamp, body, reply count
- "New Post" floating button → opens compose modal
- Infinite scroll with "Load More" button

### 3. Profile — `/profile/:username`
- Header: display name, @username, bio, follower count, following count
- Follow/Unfollow button (submits Follow/Unfollow tx)
- If own profile: "Edit Profile" button → modal for display_name + bio (submits UserUpdate tx)
- Posts tab: user's posts via `GET /api/users/:username/posts`

### 4. Post Detail — `/post/:hash`
- Full post with author info
- Parent post (if reply) shown above
- Replies listed below
- "Reply" button → compose modal with reply_to set

### 5. Search — `/search`
- Text input → searches users via `GET /api/users/search?q=...`
- Results show username, display name, bio preview

### 6. Settings — `/settings`
- Node URL configuration (default localhost:3030)
- Mnemonic backup (show mnemonic)
- Logout (clear local keys)

---

## Tauri Commands (Rust)

These run in the Tauri Rust backend for security — private keys never touch JavaScript.

```rust
#[tauri::command]
fn gen_mnemonic() -> String
// Generate a 12-word BIP39 mnemonic

#[tauri::command]
fn keypair_from_mnemonic(mnemonic: String) -> Result<KeyPair, String>
// Derive Ed25519 keypair from mnemonic
// Returns { public_key: hex, private_key: hex }

#[tauri::command]
fn sign_transaction(tx_type: String, data: String, timestamp: u64, private_key: String) -> Result<String, String>
// Sign transaction data, return hex signature
// Input data is JSON string of the tx data
```

---

## React Structure

```
src/
├── main.tsx                 # React root
├── App.tsx                  # Router + layout
├── api.ts                   # HTTP client (fetch wrapper for node API)
├── crypto.ts                # Tauri invoke wrappers
├── store/
│   ├── auth.ts              # Auth state (pubkey, username, mnemonic)
│   └── settings.ts          # Node URL, preferences
├── screens/
│   ├── Auth.tsx             # Register/Login
│   ├── Feed.tsx             # Following + Discover tabs
│   ├── Profile.tsx          # User profile
│   ├── PostDetail.tsx       # Single post + replies
│   ├── Search.tsx           # User search
│   └── Settings.tsx         # App settings
├── components/
│   ├── Layout.tsx           # Sidebar + content area
│   ├── Post.tsx             # Post card
│   ├── ComposeModal.tsx     # New post / reply modal
│   ├── ProfileHeader.tsx    # Profile top section
│   ├── UserCard.tsx         # User in search results
│   └── Loader.tsx           # Loading spinner
└── styles/
    └── globals.css          # Tailwind imports
```

---

## State Management

Use React Context + useReducer (no heavy state library needed):

**AuthContext:**
- `publicKey`, `privateKey` (hex strings, in memory only)
- `username`, `displayName`, `bio`
- `mnemonic` (for backup display)
- Persisted: only `mnemonic` to localStorage (keys derived on app start)

**SettingsContext:**
- `nodeUrl` (default "http://localhost:3030")
- Persisted to localStorage

---

## Key Dependencies

```json
{
  "dependencies": {
    "react": "^18",
    "react-dom": "^18",
    "react-router-dom": "^6",
    "@tauri-apps/api": "^2",
    "tailwindcss": "^3",
    "date-fns": "^3"
  },
  "devDependencies": {
    "typescript": "^5",
    "vite": "^5",
    "@vitejs/plugin-react": "^4"
  }
}
```

Tauri Rust deps:
```toml
[dependencies]
tauri = { version = "2", features = [] }
ed25519-dalek = { version = "2", features = ["serde"] }
bip39 = "2"
rand = "0.8"
hex = "0.4"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

---

## Build Phases

### Phase 1: Project Setup
- [ ] Initialize Tauri 2 + React + TypeScript + Vite project
- [ ] Set up TailwindCSS
- [ ] Implement Tauri Rust commands (mnemonic, keypair, signing)
- [ ] Create API client module

### Phase 2: Auth Flow
- [ ] Register screen (form → mnemonic → submit tx)
- [ ] Login screen (mnemonic → derive keys → fetch profile)
- [ ] Auth context + persistence

### Phase 3: Feed
- [ ] Feed screen with Following/Discover tabs
- [ ] Post component
- [ ] Compose modal (new post)
- [ ] Pagination (Load More)

### Phase 4: Profile & Social
- [ ] Profile screen with posts
- [ ] Follow/Unfollow functionality
- [ ] Edit profile modal
- [ ] Followers/Following lists

### Phase 5: Post Detail & Replies
- [ ] Post detail screen
- [ ] Reply list
- [ ] Reply compose

### Phase 6: Search & Settings
- [ ] User search
- [ ] Settings screen
- [ ] Node URL configuration

### Phase 7: Integration Testing (MANDATORY)

This phase is NOT optional. The frontend MUST work with the live backend before calling done.

- [ ] Start the ChainPost backend: `cd /home/agent/chainpost && cargo run -- --api-port 3030 &`
- [ ] Verify backend is running: `curl http://localhost:3030/api/info`
- [ ] Write an integration test script that exercises the full flow against the live backend:
  1. Register a new user (generate mnemonic → derive keypair → sign UserRegister tx → POST to API)
  2. Verify the user exists via `GET /api/users/<username>`
  3. Create a post (sign CreatePost tx → POST to API)
  4. Verify the post appears via `GET /api/users/<username>/posts`
  5. Register a second user, follow the first user, verify feed
- [ ] Run the integration test — ALL assertions must pass
- [ ] Use `browse` to open the frontend in Firefox and visually verify at least the auth and feed screens

### Phase 8: Polish
- [ ] Loading states and error handling
- [ ] Responsive layout
- [ ] README with setup instructions

---

## Integration Testing

The frontend is WORTHLESS if it doesn't work with the backend. Before calling `done`:

1. The backend MUST be running at localhost:3030
2. You MUST test the actual API calls the frontend makes — not just that the UI renders, but that clicking "Register" creates a real user, posting creates a real post, following works end-to-end
3. If any API call returns an error, fix it before proceeding
4. Test with `curl` or a script first (faster feedback), then verify visually with `browse`

Do NOT call `done` without passing integration tests. The verification agent will also check this.

---

## Notes

- Use `web_search` heavily throughout — Tauri 2 docs, crate API docs, TailwindCSS v4 setup
- The ChainPost backend API at localhost:3030 is the source of truth for endpoints and tx formats — explore it with `curl` before building the frontend
- When Rust crates fail to compile, search for the correct API instead of guessing fixes
