import CellKeeperCore
import Foundation
import Testing

/// The menu bar icon's settings: the Battery style with the percentage by
/// default, each saved under its own key, apart from the charging settings.
@Suite("Menu bar icon settings")
struct MenuBarIconPreferencesTests {
    @Test("Nothing stored, as for settings saved before these keys, gives the Battery style with the percentage")
    func defaults() {
        let store = SettingsStore(defaults: InMemoryStorage())
        #expect(store.loadMenuBarIconPreferences() == MenuBarIconPreferences(style: .battery, showsPercentage: true))
        #expect(MenuBarIconPreferences.default == MenuBarIconPreferences(style: .battery, showsPercentage: true))
    }

    @Test("Every combination round-trips")
    func roundTrip() {
        let store = SettingsStore(defaults: InMemoryStorage())
        for style in MenuBarIconStyle.allCases {
            for showsPercentage in [false, true] {
                let preferences = MenuBarIconPreferences(style: style, showsPercentage: showsPercentage)
                store.saveMenuBarIconPreferences(preferences)
                #expect(store.loadMenuBarIconPreferences() == preferences)
            }
        }
    }

    @Test("A value that is missing or unrecognised gets its default, whatever the other key holds")
    func unrecognised() {
        let storage = InMemoryStorage()
        let store = SettingsStore(defaults: storage)
        store.saveMenuBarIconPreferences(MenuBarIconPreferences(style: .status, showsPercentage: false))
        for unrecognised: Any in ["Status", "battery ", "", 1, true, Data("status".utf8)] {
            storage.set(unrecognised, forKey: SettingsStore.menuBarIconStyleKey)
            #expect(store.loadMenuBarIconPreferences() == MenuBarIconPreferences(style: .battery, showsPercentage: false))
        }
        store.saveMenuBarIconPreferences(MenuBarIconPreferences(style: .status, showsPercentage: false))
        for unrecognised: Any in ["OFF", "no", "", 0, false, Data("off".utf8)] {
            storage.set(unrecognised, forKey: SettingsStore.menuBarPercentageKey)
            #expect(store.loadMenuBarIconPreferences() == MenuBarIconPreferences(style: .status, showsPercentage: true))
        }
        storage.set(nil, forKey: SettingsStore.menuBarIconStyleKey)
        storage.set("off", forKey: SettingsStore.menuBarPercentageKey)
        #expect(store.loadMenuBarIconPreferences() == MenuBarIconPreferences(style: .battery, showsPercentage: false))
    }

    @Test("The icon's settings and the charging settings never affect each other when loaded")
    func keptApartFromChargingSettings() throws {
        let storage = InMemoryStorage()
        let store = SettingsStore(defaults: storage)
        let settings = ChargingSettings.default.withChargeLimit(70)
        try store.save(settings)
        storage.set("garbage", forKey: SettingsStore.menuBarIconStyleKey)
        storage.set("garbage", forKey: SettingsStore.menuBarPercentageKey)
        let loaded = store.loadChargingSettings()
        #expect(loaded.settings == settings)
        #expect(loaded.recoveryReason == nil)

        let preferences = MenuBarIconPreferences(style: .status, showsPercentage: false)
        store.saveMenuBarIconPreferences(preferences)
        storage.set(Data("not json".utf8), forKey: SettingsStore.chargingSettingsKey)
        #expect(store.loadChargingSettings().settings == SettingsStore.recoverySettings)
        #expect(store.loadMenuBarIconPreferences() == preferences)
        #expect(store.loadChargingSettings().settings == SettingsStore.recoverySettings)
    }
}
