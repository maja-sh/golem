#!/bin/bash
# Pre-scaffold a minimal Tauri 2 + React + TypeScript project.
# This gives the agent a compiling starting point so it can focus
# on building features instead of fighting framework setup.

set -e

PROJECT="$1"
if [ -z "$PROJECT" ]; then
  echo "Usage: scaffold-tauri2.sh <project-dir>"
  exit 1
fi

mkdir -p "$PROJECT/src" "$PROJECT/src-tauri/src" "$PROJECT/src-tauri/icons" "$PROJECT/src-tauri/capabilities"

# --- Frontend (Vite + React + TypeScript) ---

cat > "$PROJECT/package.json" << 'PACKAGE'
{
  "name": "tauri-app",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "tauri": "tauri"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "@tauri-apps/api": "^2.0.0",
    "@tauri-apps/plugin-shell": "^2.0.0"
  },
  "devDependencies": {
    "@tauri-apps/cli": "^2.0.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "@vitejs/plugin-react": "^4.3.0",
    "typescript": "^5.5.0",
    "vite": "^5.4.0"
  }
}
PACKAGE

cat > "$PROJECT/vite.config.ts" << 'VITE'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { usePolling: true },
  },
});
VITE

cat > "$PROJECT/tsconfig.json" << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": false,
    "noUnusedParameters": false
  },
  "include": ["src"]
}
TSCONFIG

cat > "$PROJECT/tsconfig.node.json" << 'TSNODE'
{
  "compilerOptions": {
    "composite": true,
    "skipLibCheck": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true
  },
  "include": ["vite.config.ts"]
}
TSNODE

cat > "$PROJECT/index.html" << 'HTML'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Tauri App</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
HTML

cat > "$PROJECT/src/main.tsx" << 'MAIN'
import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
MAIN

cat > "$PROJECT/src/App.tsx" << 'APP'
function App() {
  return (
    <div>
      <h1>Tauri + React</h1>
      <p>Edit src/App.tsx to get started.</p>
    </div>
  );
}

export default App;
APP

cat > "$PROJECT/src/vite-env.d.ts" << 'VITEDTS'
/// <reference types="vite/client" />
VITEDTS

# --- Backend (Tauri 2 Rust) ---

cat > "$PROJECT/src-tauri/Cargo.toml" << 'CARGO'
[package]
name = "tauri-app"
version = "0.1.0"
edition = "2021"

[lib]
name = "tauri_app_lib"
crate-type = ["staticlib", "cdylib", "rlib"]

[build-dependencies]
tauri-build = { version = "2", features = [] }

[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-shell = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
CARGO

cat > "$PROJECT/src-tauri/build.rs" << 'BUILD'
fn main() {
    tauri_build::build()
}
BUILD

cat > "$PROJECT/src-tauri/tauri.conf.json" << 'CONF'
{
  "$schema": "https://raw.githubusercontent.com/tauri-apps/tauri/dev/crates/tauri-config-schema/schema.json",
  "productName": "tauri-app",
  "version": "0.1.0",
  "identifier": "com.tauri.app",
  "build": {
    "frontendDist": "../dist",
    "devUrl": "http://localhost:1420",
    "beforeDevCommand": "npm run dev",
    "beforeBuildCommand": "npm run build"
  },
  "app": {
    "title": "Tauri App",
    "windows": [
      {
        "title": "Tauri App",
        "width": 1024,
        "height": 768
      }
    ],
    "security": {
      "csp": null
    }
  },
  "plugins": {}
}
CONF

cat > "$PROJECT/src-tauri/capabilities/default.json" << 'CAP'
{
  "$schema": "../gen/schemas/desktop-schema.json",
  "identifier": "default",
  "description": "Capability for the main window",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "shell:allow-open"
  ]
}
CAP

cat > "$PROJECT/src-tauri/src/main.rs" << 'MAINRS'
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri_app_lib::run()
}
MAINRS

cat > "$PROJECT/src-tauri/src/lib.rs" << 'LIBRS'
use tauri::Manager;

#[tauri::command]
fn greet(name: &str) -> String {
    format!("Hello, {}! You've been greeted from Rust!", name)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
LIBRS

# Create a minimal icon (Tauri needs at least one)
convert -size 32x32 xc:blue "$PROJECT/src-tauri/icons/32x32.png" 2>/dev/null || true
convert -size 128x128 xc:blue "$PROJECT/src-tauri/icons/128x128.png" 2>/dev/null || true
convert -size 128x128 xc:blue "$PROJECT/src-tauri/icons/128x128@2x.png" 2>/dev/null || true
convert -size 256x256 xc:blue "$PROJECT/src-tauri/icons/icon.png" 2>/dev/null || true
cp "$PROJECT/src-tauri/icons/icon.png" "$PROJECT/src-tauri/icons/icon.ico" 2>/dev/null || true

echo "Scaffold complete: $PROJECT"
