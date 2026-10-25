import { main } from "./lucy_osko.mjs";

console.log("[ENTRY] Starting entry.mjs, readyState:", document.readyState);
if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => {
      console.log("[ENTRY] DOMContentLoaded fired, calling main()...");
      try {
        main();
        console.log("[ENTRY] main() finished successfully! #app has children:", document.querySelector("#app") ? document.querySelector("#app").children.length : 0);
      } catch (err) {
        console.error("[Lucy Osko] Failed to start Lustre app:", err);
      }
    });
  } else {
    console.log("[ENTRY] Document ready, calling main()...");
    try {
      main();
      console.log("[ENTRY] main() finished successfully! #app has children:", document.querySelector("#app") ? document.querySelector("#app").children.length : 0);
    } catch (err) {
      console.error("[Lucy Osko] Failed to start Lustre app:", err);
    }
  }
}
