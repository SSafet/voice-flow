package com.voiceflow.mobile

import android.app.Application

class VoiceFlowApp : Application() {

    override fun onCreate() {
        super.onCreate()
        MainThreadGuard.install(this)
    }
}
