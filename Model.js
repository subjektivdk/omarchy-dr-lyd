// Parsing and lookup helpers for DR Lyd's channel directory.
//
// dr.dk/lyd/<slug> is a Next.js page that embeds the full channel directory
// (every live channel, not just the one the URL names) as SSR JSON in
// <script id="__NEXT_DATA__">. That JSON is the only source of stream URLs
// used here: DR does not publish a documented public API for this.

function extractNextData(html) {
  var match = /<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/.exec(String(html || ""))
  if (!match) return null
  try {
    return JSON.parse(match[1])
  } catch (e) {
    return null
  }
}

function isRadioChannel(entry) {
  if (!entry || typeof entry !== "object") return false
  if (!entry.slug || !Array.isArray(entry.audioAssets) || entry.audioAssets.length === 0) return false
  if (entry.type && entry.type !== "Channel") return false
  var title = String(entry.title || "")
  // DR's directory also lists internal/technical feeds (webcam preview
  // streams like "P3webcam", MCR monitoring feeds). Real radio channels are
  // titled "P<n>" or "P<n> <district>" (a digit followed by whitespace or
  // end of string — "P3webcam" fails that) or "LYD ekstra*", AND actually
  // carry an ICY (MP3) stream, which the webcam/monitoring feeds never do.
  var titleLooksLikeRadio = /^P\d(\s|$)/i.test(title) || /^LYD ekstra/i.test(title)
  return titleLooksLikeRadio && hasIcyAsset(entry)
}

function hasIcyAsset(entry) {
  for (var i = 0; i < entry.audioAssets.length; i++) {
    var asset = entry.audioAssets[i]
    if (asset && asset.format === "ICY" && asset.target === "Stream" && isHttpUrl(asset.url)) return true
  }
  return false
}

// Stream URLs come from DR's page and end up as an mpv argument. Only
// http(s) is ever expected; anything else (a path, or a string starting
// with "--" that mpv would read as an option) is dropped here.
function isHttpUrl(url) {
  return /^https?:\/\/\S+$/i.test(String(url || ""))
}

function assetsBySlug(entry) {
  var hlsUrl = ""
  var icyLow = null
  var icyHigh = null
  for (var i = 0; i < entry.audioAssets.length; i++) {
    var asset = entry.audioAssets[i]
    if (!asset || asset.target !== "Stream" || !isHttpUrl(asset.url)) continue
    if (asset.format === "HLS" && !hlsUrl) {
      hlsUrl = asset.url
    } else if (asset.format === "ICY") {
      var bitrate = asset.bitrate || 0
      if (!icyLow || bitrate < icyLow.bitrate) icyLow = { url: asset.url, bitrate: bitrate }
      if (!icyHigh || bitrate > icyHigh.bitrate) icyHigh = { url: asset.url, bitrate: bitrate }
    }
  }
  return {
    hlsUrl: hlsUrl,
    icyLowUrl: icyLow ? icyLow.url : "",
    icyHighUrl: icyHigh ? icyHigh.url : ""
  }
}

// DR titles a few channels by number only ("P6", "P8"); these are the names
// they are actually known by. Anything not listed keeps DR's own title.
var DISPLAY_NAMES = {
  p6beat: "P6 Beat",
  p8jazz: "P8 Jazz"
}

function displayTitle(entry) {
  return DISPLAY_NAMES[entry.slug] || String(entry.title || entry.slug)
}

// Walks the whole __NEXT_DATA__ tree (channel entries can sit at the top
// level or nested under a region's "districts" list) and returns a flat,
// deduplicated list of radio channels.
function parseChannelsFromNextData(data) {
  var seen = {}
  var out = []

  function walk(node) {
    if (!node || typeof node !== "object") return
    if (Array.isArray(node)) {
      for (var i = 0; i < node.length; i++) walk(node[i])
      return
    }
    if (isRadioChannel(node) && !seen[node.slug]) {
      seen[node.slug] = true
      var assets = assetsBySlug(node)
      out.push({
        slug: node.slug,
        title: displayTitle(node),
        hlsUrl: assets.hlsUrl,
        icyLowUrl: assets.icyLowUrl,
        icyHighUrl: assets.icyHighUrl
      })
    }
    for (var key in node) walk(node[key])
  }

  walk(data)
  return out
}

function parseChannelsFromHtml(html) {
  var data = extractNextData(html)
  if (!data) return []
  return parseChannelsFromNextData(data)
}

function streamUrlFor(channel, quality) {
  if (!channel) return ""
  if (quality === "Low") {
    return channel.icyLowUrl || channel.icyHighUrl || channel.hlsUrl || ""
  }
  return channel.icyHighUrl || channel.icyLowUrl || channel.hlsUrl || ""
}

function regionOf(slug) {
  if (/^p4/i.test(slug)) return "p4"
  if (/^p5/i.test(slug)) return "p5"
  return ""
}

// Groups the flat channel list for display: favorited channels first (in
// their own heading, removed from their regular group below), then
// nationwide channels, then the two regional families each collapsed under
// one heading.
function groupChannels(channels, favoriteSlugs) {
  var favSet = {}
  var favs = Array.isArray(favoriteSlugs) ? favoriteSlugs : []
  for (var f = 0; f < favs.length; f++) favSet[favs[f]] = true

  var favorites = []
  var rest = []
  for (var i = 0; i < channels.length; i++) {
    if (favSet[channels[i].slug]) favorites.push(channels[i])
    else rest.push(channels[i])
  }

  var national = []
  var p4 = []
  var p5 = []

  for (var j = 0; j < rest.length; j++) {
    var ch = rest[j]
    var region = regionOf(ch.slug)
    if (region === "p4") p4.push(ch)
    else if (region === "p5") p5.push(ch)
    else national.push(ch)
  }

  function byTitle(a, b) { return a.title.localeCompare(b.title) }
  favorites.sort(byTitle)
  national.sort(byTitle)
  p4.sort(byTitle)
  p5.sort(byTitle)

  // `key` is the stable id the panel remembers collapse state under; the
  // ten-channel regional families start collapsed so favorites and the
  // nationwide channels fit without scrolling.
  var groups = []
  if (favorites.length) groups.push({ key: "favorites", label: "Favoritter", items: favorites, defaultCollapsed: false })
  if (national.length) groups.push({ key: "national", label: "Landsdækkende", items: national, defaultCollapsed: false })
  if (p4.length) groups.push({ key: "p4", label: "P4 regional", items: p4, defaultCollapsed: true })
  if (p5.length) groups.push({ key: "p5", label: "P5 regional", items: p5, defaultCollapsed: true })
  return groups
}

// Parses the plugin's persisted state file (favorites, last played channel,
// which groups the user has expanded/collapsed). Missing/corrupt state is
// treated as "nothing saved yet".
function parseStateFile(raw) {
  var favorites = []
  var lastPlayed = ""
  var groups = {}
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (parsed && Array.isArray(parsed.favorites))
      favorites = parsed.favorites.filter(function(s) { return typeof s === "string" && s })
    if (parsed && typeof parsed.lastPlayed === "string") lastPlayed = parsed.lastPlayed
    if (parsed && parsed.groups && typeof parsed.groups === "object" && !Array.isArray(parsed.groups)) {
      for (var key in parsed.groups)
        if (typeof parsed.groups[key] === "boolean") groups[key] = parsed.groups[key]
    }
  } catch (e) {
    // First run or corrupt file: fall back to empty state.
  }
  return { favorites: favorites, lastPlayed: lastPlayed, groups: groups }
}
