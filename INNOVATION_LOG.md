# INNOVATION_LOG — Sora/Sulfur (autonomous loop)

## Backlog (impact-ordered)
- [En progreso] Offline Module Caching: persistent module caching with SQLite + conditional HTTP validation (ETag/Last-Modified) for offline browsing.
- [ ] SwiftSoup edge cases: invalid selector, empty HTML, missing element — harden `SwiftSoupParser`/`querySelector(All)` paths + unit tests.
- [ ] Bound `SoraJSEngine` timer registry growth (cleared intervals leave cancelled work items until `cleanup`).
- [ ] Prefetch next-episode stream URL while current plays (latency hiding).

## Done
- [x] Cancel in-flight JS work on module switch (`moduleGeneration` counter +
  `withGeneration` guard; all public async entry points check generation before
  resolving). Suite 44/44 green.
- [x] Liquid Glass polish: `GlassCluster` modifier (shared sampling region) +
  xmark circle converted to `.adaptiveGlass(Circle)` for glass unity.
  Suite 44/44 green. (Note: `glassEffectID` morphing deferred — needs visual QA.)
- [x] `parseStreamResult` dedupe: single shared `StreamResultParser` + 4 direct
  unit tests. Suite 44/44 green.
- [x] Timeout + watchdog for async JS promises (`JSPromiseBox` resume-once +
  cancellable deadline, `JSExecutionError.timedOut`, 0.5s test). Suite 40/40.
- [x] JSContext pool: `JSController` reuses one `SoraModuleInstance` per module
  (fingerprint version+script, LRU cap 8, `.moduleRemoved` invalidation).
  Proven by identity (`===`) + re-parse-on-version tests. Suite 39/39 green.
- [x] Fix `AdaptiveGlass`: real SDK signature is `glassEffect(_:in:)`
  (no `isEnabled`); branch on theme/transparency instead. Suite 37/37 green.
- [x] `soraWebFetch` retention fix validated (`WebFetchMonitor` retained in
  `JSBridge.webFetchMonitors`; local-HTML test passes).
- [x] Exception mirroring (`lastException` + `ctx.exception`) — JSC drops
  `context.exception` when a handler is set.
- [x] Template-literal regex fix (`[\\s\\S]` in `soraGetElementsByTag`).
- [x] Native `setTimeout`/`setInterval` (JS self-recursion = stack overflow).
- [x] `NovelFallback.swift` native chapter fallback + `writeSettingsToFile`
  regex fix.
- [x] In-flight JS cancellation (`moduleGeneration` + `withGeneration` guard; all
  public async entry points check generation before resolving). Suite 44/44
  green.
