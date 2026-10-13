// DemoPage.swift

import Foundation

/// A built-in page that exercises CEFWebView's page-facing API: script messages, pop-ups and links
/// the navigation policy handles.
enum DemoPage {
    static let html = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <title>CEFWebView Demo</title>
    <style>
      body { font: 15px -apple-system, sans-serif; margin: 32px; max-width: 640px; color: #222; }
      @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #ddd; } a { color: #6af; } }
      button { font: inherit; margin: 4px 8px 4px 0; }
      section { margin-bottom: 24px; }
      code { font-size: 13px; }
    </style>
    </head>
    <body>
    <h1>CEFWebView Demo</h1>

    <section>
      <h3>Messages to Swift</h3>
      <p><code>window.cefWebView.postMessage("greeting", body)</code></p>
      <button onclick="cefWebView.postMessage('greeting', {text: 'Hello from the page', sentAt: Date.now()})">Send greeting</button>
      <button onclick="cefWebView.postMessage('greeting', document.getElementById('note').value)">Send note</button>
      <input id="note" value="A note from the page">
    </section>

    <section>
      <h3>Pop-ups</h3>
      <p>The demo opens these in a new window.</p>
      <button onclick="window.open('https://example.com/')">window.open example.com</button>
      <a href="https://www.chromium.org/" target="_blank">target=_blank chromium.org</a>
    </section>

    <section>
      <h3>Navigation policy</h3>
      <p>Links outside the web open in their own app; the view never navigates to them.</p>
      <a href="mailto:someone@example.com">mailto: link</a>
    </section>

    <section>
      <h3>JavaScript from Swift</h3>
      <p>Tools → Count Links runs <code>document.links.length</code> in this page.</p>
      <p id="counter">Counter: 0</p>
      <script>
        let count = 0;
        function increment() {
          count += 1;
          document.getElementById('counter').textContent = 'Counter: ' + count;
          return count;
        }
      </script>
    </section>
    </body>
    </html>
    """
}
