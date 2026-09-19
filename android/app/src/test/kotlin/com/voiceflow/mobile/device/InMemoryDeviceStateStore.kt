package com.voiceflow.mobile.device

/**
 * The durable device state without Android: the same shape the preferences
 * store keeps. Work package P2 keeps the device id and the account here; no
 * access token and no refresh token are ever written (05 §3.2 "Access tokens",
 * 08 §3.3 "No refresh credential exists on this phone").
 */
internal class InMemoryDeviceStateStore(private var account: DeviceAccount? = null) : DeviceStateStore {

    var saves = 0
        private set
    var clears = 0
        private set

    override fun load(): DeviceAccount? = account

    override fun save(account: DeviceAccount) {
        this.account = account
        saves++
    }

    override fun clear() {
        account = null
        clears++
    }
}
