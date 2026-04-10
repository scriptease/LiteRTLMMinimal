import SwiftUI
import LiteRTLM

struct ContentView: View {
    @State private var results: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            Text("LiteRT-LM Minimal")
                .font(.title)

            Button("Test API Linkage") {
                runTests()
            }
            .buttonStyle(.borderedProminent)

            List(results, id: \.self) { result in
                Text(result)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .padding()
    }

    private func runTests() {
        results.removeAll()

        // 1. Set log level (no model needed)
        litert_lm_set_min_log_level(2)
        results.append("set_min_log_level(2): OK")

        // 2. Create and configure a session config
        if let config = litert_lm_session_config_create() {
            litert_lm_session_config_set_max_output_tokens(config, 256)
            litert_lm_session_config_delete(config)
            results.append("session_config create/set/delete: OK")
        } else {
            results.append("session_config_create: FAILED (nil)")
        }

        // 3. Create engine settings (no real model — just linkage proof)
        if let settings = litert_lm_engine_settings_create(
            "/nonexistent", "cpu", nil, nil
        ) {
            litert_lm_engine_settings_set_max_num_tokens(settings, 1024)
            litert_lm_engine_settings_delete(settings)
            results.append("engine_settings create/set/delete: OK")
        } else {
            results.append("engine_settings_create: nil (expected)")
        }

        results.append("")
        results.append("All LiteRT-LM symbols resolved.")
    }
}
