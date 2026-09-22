/** Native Mac capability bridge. Intentionally separate from T3's Electron DesktopBridge.
 * Browser builds leave window.voiceFlowShell undefined. T3 owns drafts, uploads,
 * connection retries, subscriptions and sends. This bridge never sends a turn.
 */
export interface ShellComposerTarget {
  readonly environmentId: string;
  readonly kind: "thread" | "draft";
  readonly id: string;
  /** Unique per mounted composer, so unmount/remount cannot steal a frozen input. */
  readonly composerId: string;
}
export interface ShellFrozenTarget {
  readonly documentId: string;
  readonly target: ShellComposerTarget;
}
export interface ShellInput {
  readonly deliveryId: string;
  readonly destination: ShellFrozenTarget;
  readonly text: string;
  /** Opaque IDs from existing native capture services; not filesystem paths. */
  readonly captureIds: readonly string[];
}
export interface ShellInputReceipt {
  readonly deliveryId: string;
  /** accepted only after the correct draft and delivery ID are durably recorded.
   * unconfirmed means the effect may have committed: retain native source and
   * reconcile/retry the SAME ID, never insert under a fresh ID automatically.
   */
  readonly status: "accepted" | "stale-target" | "unavailable" | "rejected" | "unconfirmed";
}
export type ShellCapability = "dictate" | "capture" | "speak" | "stopSpeaking" | "openNativeSettings";
export interface ShellCapabilityRequest {
  readonly capability: ShellCapability;
  /** Required for dictate/capture; native checks the current frozen target. */
  readonly destination?: ShellFrozenTarget;
  readonly text?: string;
}
export interface VoiceFlowShell {
  readonly version: 1;
  describe(): Promise<{
    readonly version: 1;
    readonly documentId: string;
    /** Render only these actions; callbacks absent in native are not advertised. */
    readonly capabilities: readonly ShellCapability[];
  }>;
  publishComposerTarget(documentId: string, target: ShellComposerTarget | null): Promise<{ accepted: boolean }>;
  perform(request: ShellCapabilityRequest): Promise<{
    readonly status: "completed" | "cancelled" | "unavailable" | "rejected";
  }>;
  /** One active consumer. Unsubscribe only removes that registration. On delivery,
   * validate frozen target before mutating; deduplicate using the durable draft API.
   * Preserve unrelated typing and selection. Capture IDs need native upload wiring;
   * reject unsupported captures instead of accepting text and silently dropping them.
   */
  onInput(handler: (input: ShellInput) => Promise<ShellInputReceipt>): () => void;
  /** Renewed cookie is already installed. Wake T3's existing auth supervisor;
   * do not reload, recreate the runtime, clear drafts or retry a user send.
   */
  onCredentialsChanged(handler: () => void): () => void;
}
declare global {
  interface Window { readonly voiceFlowShell?: VoiceFlowShell }
}
