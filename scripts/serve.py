#!/usr/bin/env python3
import sys
import os
from http import server

class CoepCoopHandler(server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # Cross-Origin Isolation required for WebAssembly pthreads / SharedArrayBuffer
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    directory = sys.argv[2] if len(sys.argv) > 2 else "dist"
    
    class DirectoryHandler(CoepCoopHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)
            
    print(f"[Lucy Osko Web] Server running at http://localhost:{port}")
    print(f"[Lucy Osko Web] Serving '{directory}' with COOP/COEP headers enabled for Wasm pthreads.")
    print("Press Ctrl+C to stop.")
    server.test(HandlerClass=DirectoryHandler, port=port)

if __name__ == "__main__":
    main()
