// SwiftMaestro Web Clipper — full-metadata bundle entry
//
// Rebuilds the SwiftMaestro clipper bundle against the official Obsidian
// Web Clipper toolchain (Defuddle 0.16 + defuddle/full markdown w/ Temml).
//
// Unlike the original entry, this returns the COMPLETE Defuddle parse —
// the fields the old bridge discarded (domain, favicon, image, language,
// wordCount, metaTags, schemaOrgData, extractor variables) now round-trip
// to Swift for the template engine and MaestroDB clip library.
//
// Build (from the obsidian-clipper repo root):
//   node_modules/.bin/esbuild src/swiftmaestro-clipper.ts \
//     --bundle --format=iife --minify \
//     --outfile=dist/swiftmaestro-clipper.js
//
// Then copy dist/swiftmaestro-clipper.js into
//   SwiftMaestro/Sources/Resources/swiftmaestro-clipper.js

import Defuddle from 'defuddle';
import { createMarkdownContent } from 'defuddle/full';

interface SwiftMaestroClipResult {
	// Core content (same as the legacy bridge)
	title: string;
	url: string;
	excerpt: string;
	author: string;
	published: string;
	site: string;
	markdown: string;
	html: string;
	// Full metadata (new — previously discarded by the bridge)
	description: string;
	domain: string;
	favicon: string;
	image: string;
	language: string;
	wordCount: number;
	metaTags: { name: string | null; property: string | null; content: string }[];
	schemaOrg: any;               // JSON-LD block(s) — object, array, or null
	extractorType: string;        // e.g. "youtube", "github" when a site extractor fired
	variables: Record<string, string>; // extractor extras (transcripts, etc.)
}

function safeHostname(url: string): string {
	try {
		return new URL(url).hostname.replace(/^www\./, '');
	} catch {
		return '';
	}
}

/**
 * Defuddle reads domain from doc.location.href — which is about:blank inside
 * SwiftMaestro's hidden WKWebView (the page HTML is re-parsed from a string).
 * Fall back to the URL argument when Defuddle couldn't resolve a domain from
 * og:url / canonical / schema.org.
 *
 * Similarly, schemaOrgData extraction can misfire depending on the DOM
 * implementation's script textContent handling — fall back to a direct
 * JSON-LD collection when Defuddle found none.
 */
function collectJsonLd(doc: Document): any {
	const blocks: any[] = [];
	const scripts = doc.querySelectorAll('script[type="application/ld+json"]');
	scripts.forEach((script) => {
		const text = (script.textContent || '').trim();
		if (!text) return;
		try {
			const parsed = JSON.parse(text);
			if (parsed && parsed['@graph'] && Array.isArray(parsed['@graph'])) {
				blocks.push(...parsed['@graph']);
			} else {
				blocks.push(parsed);
			}
		} catch {
			// Malformed JSON-LD — skip rather than fail the clip.
		}
	});
	if (blocks.length === 0) return null;
	return blocks.length === 1 ? blocks[0] : blocks;
}

function clip(html: string, url: string): string {
	const parser = new DOMParser();
	const doc = parser.parseFromString(html, 'text/html');
	const parsed = new Defuddle(doc, { url }).parse();
	const markdown = createMarkdownContent(parsed.content, url);

	const result: SwiftMaestroClipResult = {
		title: parsed.title ?? '',
		url,
		excerpt: parsed.description ?? '',
		author: parsed.author ?? '',
		published: parsed.published ?? '',
		site: parsed.site ?? '',
		markdown,
		html: parsed.content,
		description: parsed.description ?? '',
		domain: parsed.domain || safeHostname(url),
		favicon: parsed.favicon ?? '',
		image: parsed.image ?? '',
		language: parsed.language ?? '',
		wordCount: parsed.wordCount ?? 0,
		metaTags: (parsed.metaTags ?? []).map((t) => ({
			name: t.name ?? null,
			property: t.property ?? null,
			content: t.content ?? ''
		})),
		schemaOrg: parsed.schemaOrgData ?? collectJsonLd(doc),
		extractorType: parsed.extractorType ?? '',
		variables: parsed.variables ?? {}
	};
	return JSON.stringify(result);
}

// Expose for the Swift WKWebView bridge.
(window as any).swiftMaestroClip = clip;
