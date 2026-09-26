//
//  ContentView.swift
//  Small Matter
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settingsManager: SettingsManager

    var body: some View {
        AppShellView(settingsManager: settingsManager)
    }
}
