# Winnow Lightning research app privacy

Winnow Lightning is a regtest research app. It does not use a developer-operated account, analytics service, or advertising SDK. The app's 64-byte node seed is stored in the device Keychain. Channel and wallet state are stored in the app's local storage. Peer IDs and public keys, and the Esplora URL you choose, are stored in local app preferences.

When you start the node, it contacts the regtest Esplora server you entered and any Lightning peer you configured. Those servers and peers can observe your IP address and the chain, channel, and payment requests you send to them. The app does not relay those requests through Winnow. Use a server and peer you trust for testing.

The app copies an address, key, or invoice to the clipboard only when you tap Copy. If you share that text elsewhere, the receiving app or person controls how it is handled. Apple's TestFlight and device diagnostics may separately collect crash and usage information under your Apple settings.

This research build is for disposable regtest coins only. It stops in the background and has no watchtower. Deleting the app can remove channel state; the seed alone does not reconstruct that state.

For questions, use the public [winnow-lightning issue tracker](https://github.com/posix4e/winnow-lightning/issues).
