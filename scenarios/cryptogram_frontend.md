# Cryptogram Frontend: Tauri + React Desktop Client

**Difficulty:** Hard
**Expected steps:** 150-300
**Recommended max_steps:** 400
**Language:** TypeScript/React + Rust (Tauri)

## Goal

Build a desktop client for the Cryptogram blockchain microblogging platform using Tauri 2 + React. The client connects to a Cryptogram node's API and provides a Twitter-like experience for creating accounts, posting, following users, and browsing feeds.

### Environment

You have root access to a Ubuntu 24.04 container. Install Node.js 20+ (already available), Rust (install via rustup), and Tauri prerequisites. Firefox is available on DISPLAY=:99 for visual testing.

Put everything in `/home/agent/cryptogram-client/`.

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
│        Cryptogram Node API               │
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

### Phase 7: Polish
- [ ] Use `browse` to visually verify each screen
- [ ] Loading states and error handling
- [ ] Responsive layout
- [ ] README with screenshots and setup instructions

---

## Visual Testing

Use the `browse` tool to open the Tauri dev server in Firefox on the virtual display and take screenshots to verify the UI looks correct. Check:
- Auth screens render properly
- Feed shows posts with correct layout
- Profile page displays user info
- Compose modal opens and submits

---

## Reference Code

The operator's previous frontend is at `/Users/hbackman/workspace2/cryptogram-client`. Key files:
- `src/store/auth.js` — Auth state with mnemonic/keypair management
- `src/screens/` — Screen layouts (Vue, but the UX patterns apply)
- `src/components/post/Post.vue` — Post card design
- `src-tauri/src/lib.rs` — Tauri crypto commands

This rebuild uses React instead of Vue, but the UX flow should be similar.
