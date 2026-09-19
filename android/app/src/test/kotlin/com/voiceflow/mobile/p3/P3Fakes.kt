package com.voiceflow.mobile.p3

import com.voiceflow.mobile.generated.AttachmentKind
import com.voiceflow.mobile.generated.AuthSignInResult
import com.voiceflow.mobile.generated.AuthTokenResult
import com.voiceflow.mobile.generated.DictateStartResult
import com.voiceflow.mobile.generated.DictateStopResult
import com.voiceflow.mobile.generated.Endpoint
import com.voiceflow.mobile.generated.EndpointAuthMode
import com.voiceflow.mobile.generated.EndpointID
import com.voiceflow.mobile.generated.EndpointKind
import com.voiceflow.mobile.generated.EndpointState
import com.voiceflow.mobile.generated.FilesSaveResult
import com.voiceflow.mobile.generated.FormFactor
import com.voiceflow.mobile.generated.NotifyResult
import com.voiceflow.mobile.generated.PermissionRow
import com.voiceflow.mobile.generated.PermissionState
import com.voiceflow.mobile.generated.ShellDescriptor
import com.voiceflow.mobile.generated.ShellName
import com.voiceflow.mobile.generated.ShellPlatform
import com.voiceflow.mobile.generated.SpeakStartResult
import com.voiceflow.mobile.shell.ShellContract
import com.voiceflow.mobile.shell.ShellHost

/**
 * The one stand-in for the native capability port, shared by the P3 tests.
 *
 * It is not a second implementation: every method returns the value the test
 * set, and records that the bridge reached it. The rules under test —
 * version refusal, capability gating, parameter validation, error mapping,
 * cleaning, the same-origin attachment address — all live in the bridge, not
 * here, so an assertion about them cannot pass by being asserted back at a
 * double. A method the test did not configure with a value answers with the
 * default below.
 */
internal open class FakeShellHost : ShellHost {

    val calls = mutableListOf<String>()

    var readyBuildId: String? = null
    var escapeHandled: Boolean = false
    var lastNotifyTitle: String? = null
    var lastSpeakText: String? = null
    var lastExternalOpen: String? = null
    var lastPermissionOpen: String? = null
    var lastSignOut: EndpointID? = null

    var dictateStartFailure: Throwable? = null
    var notifyFailure: Throwable? = null
    var accessTokenFailure: Throwable? = null

    var dictateStartResult: DictateStartResult = DictateStartResult(captureID = "dict-0001")
    var dictateStopResult: DictateStopResult = DictateStopResult(text = "fix the cart button")
    var speakStartResult: SpeakStartResult = SpeakStartResult(playbackID = "play-0001")
    var notifyResult: NotifyResult = NotifyResult(shown = true)
    var filesSaveResult: FilesSaveResult = FilesSaveResult(started = true)
    var accessTokenResult: AuthTokenResult =
        AuthTokenResult(accessToken = "tok-0001", expiresAt = "2026-09-19T10:00:00Z")
    var signInResult: AuthSignInResult = AuthSignInResult(started = true)
    var stagedAttachments: List<StagedAttachment> = emptyList()
    var permissionRows: List<PermissionRow> = emptyList()

    override fun descriptor(): ShellDescriptor = ShellDescriptor(
        account = null,
        capabilities = ShellContract.ANDROID_CAPABILITIES,
        endpoints = listOf(
            Endpoint(
                authMode = EndpointAuthMode.ShellToken,
                baseURL = "https://atika.ai",
                id = EndpointID.Cloud,
                kind = EndpointKind.Atika,
                label = "Atika",
                state = EndpointState.SignedOut,
                stateReason = "revoked",
            ),
        ),
        interfaceBuildID = "7cbe540d",
        platform = ShellPlatform(formFactor = FormFactor.Phone, os = "Android", osVersion = "16"),
        shell = ShellName.Android,
        shellVersion = "2.0.0",
        v = 1,
    )

    override fun ready(buildId: String) {
        calls += "shell.ready"
        readyBuildId = buildId
    }

    override fun escape(): Boolean {
        calls += "shell.escape"
        return escapeHandled
    }

    override fun accessToken(endpointId: EndpointID): AuthTokenResult {
        calls += "auth.token"
        accessTokenFailure?.let { throw it }
        return accessTokenResult
    }

    override fun signIn(endpointId: EndpointID): AuthSignInResult {
        calls += "auth.signIn"
        return signInResult
    }

    override fun signOut(endpointId: EndpointID) {
        calls += "auth.signOut"
        lastSignOut = endpointId
    }

    override fun dictateStart(threadId: String?): DictateStartResult {
        calls += "dictate.start"
        dictateStartFailure?.let { throw it }
        return dictateStartResult
    }

    override fun dictateStop(captureId: String): DictateStopResult {
        calls += "dictate.stop"
        return dictateStopResult
    }

    override fun speakStart(text: String, threadId: String): SpeakStartResult {
        calls += "speak.start"
        lastSpeakText = text
        return speakStartResult
    }

    override fun speakStop(playbackId: String) {
        calls += "speak.stop"
    }

    override fun notify(threadId: String, title: String, body: String, tag: String): NotifyResult {
        calls += "notify"
        lastNotifyTitle = title
        notifyFailure?.let { throw it }
        return notifyResult
    }

    override fun filesPick(multiple: Boolean, accept: List<String>): List<StagedAttachment> {
        calls += "files.pick"
        return stagedAttachments
    }

    override fun filesSave(url: String, name: String): FilesSaveResult {
        calls += "files.save"
        return filesSaveResult
    }

    override fun permissionsList(): List<PermissionRow> {
        calls += "permissions.list"
        return permissionRows
    }

    override fun permissionsOpen(id: String) {
        calls += "permissions.open"
        lastPermissionOpen = id
    }

    override fun externalOpen(url: String) {
        calls += "external.open"
        lastExternalOpen = url
    }
}

internal fun stagedFile(id: String = "att-0001", name: String = "invoice.pdf"): StagedAttachment =
    StagedAttachment(
        id = id,
        kind = AttachmentKind.File,
        mime = "application/pdf",
        bytes = 48213L,
        name = name,
    )

internal fun permissionRow(id: String = "microphone", state: PermissionState = PermissionState.Ok): PermissionRow =
    PermissionRow(
        actionLabel = "Open settings",
        detail = "Needed to dictate.",
        id = id,
        state = state,
        title = "Microphone",
    )

internal fun rowState(rows: List<PermissionRow>, id: String): PermissionState? =
    rows.firstOrNull { it.id == id }?.state
