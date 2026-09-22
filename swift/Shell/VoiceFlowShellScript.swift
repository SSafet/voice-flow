import Foundation

enum VoiceFlowShellScript {
    /// Only a matching trusted main document receives this namespace. No token,
    /// native path, DesktopBridge impersonation or canonical data is injected.
    static func source(origin: T3ShellOrigin) throws -> String {
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [origin.url.absoluteString]), as: UTF8.self)
        return """
        (() => {
          if (window !== window.top || location.origin !== \(encoded)[0]) return;
          const invoke = (type, fields = {}) => window.webkit.messageHandlers.voiceFlowShell.postMessage({version: 1, type, ...fields});
          let inputHandler = null;
          const credentialsHandlers = new Set();
          const bridge = {
            version: 1,
            describe: () => invoke('describe'),
            publishComposerTarget: (documentId, target) => invoke('composer', {documentId, target}),
            perform: request => invoke('perform', {request}),
            onInput: handler => {
              if (typeof handler !== 'function') throw new TypeError('Input handler must be a function.');
              if (inputHandler !== null) throw new Error('A native input consumer is already registered.');
              inputHandler = handler;
              return () => { if (inputHandler === handler) inputHandler = null; };
            },
            onCredentialsChanged: handler => {
              if (typeof handler !== 'function') throw new TypeError('Credentials handler must be a function.');
              credentialsHandlers.add(handler);
              return () => credentialsHandlers.delete(handler);
            }
          };
          Object.defineProperties(bridge, {
            __deliver: {value: async input => {
              if (!inputHandler) return {deliveryId: input.deliveryId, status: 'unavailable'};
              // The durable T3 draft consumer validates the target and deduplicates
              // IDs. An exception is indeterminate, never proof nothing committed.
              try { return await inputHandler(input); }
              catch { return {deliveryId: input.deliveryId, status: 'unconfirmed'}; }
            }},
            __credentialsChanged: {value: () => {
              for (const handler of credentialsHandlers) { try { handler(); } catch {} }
            }}
          });
          Object.defineProperty(window, 'voiceFlowShell', {value: Object.freeze(bridge), configurable: false, writable: false});
        })();
        """
    }
}
