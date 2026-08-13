import SwiftUI

struct WatchWorkoutView: View {
    @EnvironmentObject private var workout: WatchWorkoutManager

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(workout.state)
                    .font(.headline)

                HStack {
                    watchMetric("HR", workout.heartRateBPM, suffix: "bpm", digits: 0)
                    watchMetric("Active", workout.activeEnergyKcal, suffix: "kcal", digits: 1)
                }

                HStack {
                    watchMetric("Floors", workout.machineMetrics?.floors.map { Double($0) }, suffix: "", digits: 0)
                    watchMetric("SPM", workout.machineMetrics?.stepsPerMinute.map { Double($0) }, suffix: "", digits: 0)
                }

                if workout.state == "Running" || workout.state == "Paused" {
                    Button("End workout", role: .destructive) {
                        workout.end()
                    }
                } else if workout.state == "Not started" || workout.state == "Saved" {
                    Text("Start and select the ClimbMill on iPhone.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                if let error = workout.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func watchMetric(
        _ title: String,
        _ value: Double?,
        suffix: String,
        digits: Int
    ) -> some View {
        VStack(spacing: 2) {
            Text(value?.formatted(.number.precision(.fractionLength(digits))) ?? "--")
                .font(.title3.bold())
                .monospacedDigit()
            Text(suffix.isEmpty ? title : "\(title) \(suffix)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
