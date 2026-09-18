# BACKLOG — Sora/Sulfur (autonomous loop)

- [x] Retain `WebFetchMonitor` until completion (`soraWebFetch` never resolves: local `monitor` deallocs when `performWebFetch` returns). Added `JSBridge.webFetchMonitors[id]`, release on completion, added local-HTML test.
- [ ] SwiftSoup edge cases: invalid selector, empty HTML, missing element — harden `SwiftSoupParser`/`querySelector(All)` paths + unit tests.
- [ ] Dedupe `parseStreamResult` (copy-pasted in 4 execution-mode handlers) into one shared parser + unit tests.
- [ ] Liquid Glass polish: `GlassEffectContainer` around the TabBar cluster + selected-tab morphing via `glassEffectID` (iOS 26+ only, classic fallback kept).
- [ ] Cancel in-flight JS work on module switch (abandoned continuations + WKWebView loads keep running after `invalidateModule`).
- [ ] Dedup concurrent identical module calls (coalesce parallel search/details/stream requests for the same input).
- [ ] Bound `SoraJSEngine` timer registry growth (cleared intervals leave cancelled work items until `cleanup`).
- [ ] Prefetch next-episode stream URL while current plays (latency hiding).

# Next Priority: Offline Module Caching
- [ ] **New Spec**: Persistent module caching for offline access — cache validated JS modules + metadata to disk (SQLite/JSON), enable offline browsing, cache invalidation on remote version change.