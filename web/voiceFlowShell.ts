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
export interface ShellCaptureReadRequest {
  readonly deliveryId: string; readonly captureId: string; readonly offset: number; readonly maxBytes: number;
}
export interface ShellCaptureReadReply {
  readonly captureId: string; readonly name: string; readonly mimeType: string;
  readonly sizeBytes: number; readonly sha256: string; readonly offset: number; readonly base64: string;
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
  /** Owned immutable source only, exact frozen target, 1..524288-byte chunks. */
  readCapture(request: ShellCaptureReadRequest): Promise<ShellCaptureReadReply>;
  perform(request: ShellCapabilityRequest): Promise<{
    readonly status: "completed" | "cancelled" | "unavailable" | "rejected";
  }>;
  /** One active consumer. Unsubscribe only removes that registration. On delivery,
   * reconcile an exact committed receipt before target checks; otherwise validate
   * the frozen target before reads and mutation. Upload via readCapture, verify the
   * full hash, and atomically commit existing draft + attachments + receipt.
   * Preserve unrelated typing and selection; never accept dropped captures.
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
