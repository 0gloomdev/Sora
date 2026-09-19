// Torrentio Scraping Module for Sora
// Compatible with SoraJSEngine expected signatures

const TORRENTIO_BASE = "https://torrentio.org";
const MANIFEST_URL = `${TORRENTIO_BASE}/manifest.json`;

// Helper functions for Sora compatibility
function log(message) {
    console.log(`[Torrentio] ${message}`);
}

function fetchUrl(url, options = {}) {
    return fetch(url, {
        headers: {
            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15',
            'Accept': 'application/json, text/html, */*',
            ...options.headers
        },
        timeout: 15000,
        ...options
    });
}

// Main extraction function expected by SoraJSEngine
async function extractMedia(params) {
    const { url, type, title, year, season, episode } = params;
    
    log(`Extracting media: ${type} - ${title} (${year})`);
    
    try {
        // Fetch manifest if not cached
        const manifest = await fetchManifest();
        if (!manifest) {
            throw new Error('Failed to fetch manifest');
        }
        
        // Find matching stream
        const streams = await resolveStreams(manifest, type, title, year, season, episode);
        
        if (!streams || streams.length === 0) {
            throw new Error('No streams found');
        }
        
        return formatStreams(streams);
        
    } catch (error) {
        log(`Error: ${error.message}`);
        throw error;
    }
}

// Fetch and cache Torrentio manifest
let cachedManifest = null;
async function fetchManifest() {
    if (cachedManifest) return cachedManifest;
    
    try {
        const response = await fetchUrl(MANIFEST_URL);
        if (!response.ok) throw new Error(`Manifest fetch failed: ${response.status}`);
        
        const data = await response.json();
        cachedManifest = data;
        return data;
    } catch (error) {
        log(`Manifest fetch failed: ${error.message}`);
        return null;
    }
}

// Resolve streams based on manifest and media parameters
async function resolveStreams(manifest, type, title, year, season, episode) {
    const streams = [];
    const query = buildSearchQuery(type, title, year, season, episode);
    
    // Search in catalogs
    for (const catalog of manifest.catalogs || []) {
        try {
            const catalogUrl = `${TORRENTIO_BASE}${catalog.url.replace('{query}', encodeURIComponent(query))}`;
            const response = await fetchUrl(catalogUrl);
            if (!response.ok) continue;
            
            const data = await response.json();
            const metas = data.metas || [];
            
            for (const meta of metas) {
                const stream = await resolveMeta(meta);
                if (stream) streams.push(stream);
            }
        } catch (e) {
            log(`Catalog error: ${e.message}`);
        }
    }
    
    return streams;
}

// Build search query from media info
function buildSearchQuery(type, title, year, season, episode) {
    let query = title;
    if (year) query += ` ${year}`;
    if (type === 'series' && season && episode) {
        query += ` S${String(season).padStart(2, '0')}E${String(episode).padStart(2, '0')}`;
    }
    return query;
}

// Resolve individual meta to stream
async function resolveMeta(meta) {
    try {
        if (!meta.id) return null;
        
        const streamsUrl = `${TORRENTIO_BASE}/stream/${meta.type}/${meta.id}.json`;
        const response = await fetchUrl(streamsUrl);
        if (!response.ok) return null;
        
        const data = await response.json();
        const streams = data.streams || [];
        
        return streams.map(s => ({
            url: s.url,
            title: s.title || meta.name,
            quality: parseQuality(s.quality || s.name || ''),
            source: 'torrentio',
            behaviorHints: s.behaviorHints || {}
        }));
    } catch (e) {
        return null;
    }
}

// Parse quality string to standardized format
function parseQuality(qualityStr) {
    const q = qualityStr.toLowerCase();
    if (q.includes('4k') || q.includes('2160')) return '4K';
    if (q.includes('1080') || q.includes('fhd')) return '1080p';
    if (q.includes('720') || q.includes('hd')) return '720p';
    if (q.includes('480')) return '480p';
    return 'SD';
}

// Format streams for Sora consumption
function formatStreams(streams) {
    return streams
        .filter(s => s.url && s.url.startsWith('http'))
        .map(s => ({
            url: s.url,
            title: s.title || 'Torrentio Stream',
            quality: s.quality,
            source: s.source || 'torrentio',
            behaviorHints: {
                notWebReady: true,
                proxyHeaders: {
                    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15'
                }
            },
            ...s.behaviorHints
        });
    }
}

// Export for SoraJSEngine
if (typeof module !== 'undefined' && module.exports) {
    module.exports = { extractMedia, fetchManifest, resolveStreams, parseQuality };
}

// SoraJSEngine compatibility
if (typeof globalThis !== 'undefined') {
    globalThis.extractMedia = globalThis.extractMedia || extractMedia;
    globalThis.fetchManifest = globalThis.fetchManifest || fetchManifest;
    globalThis.resolveStreams = globalThis.resolveStreams || resolveStreams;
    globalThis.parseQuality = globalThis.parseQuality || parseQuality;
}