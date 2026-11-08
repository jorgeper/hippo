import SwiftUI
import CaptureCore
import LocalRepository
import HippoPresentation

struct FiltersSheet: View {
    @Binding var filters: SheetFilters
    @Environment(\.dismiss) private var dismiss

    private enum DateChoice: Hashable { case any, today, last7, last30, custom }

    private static let types: [(ContentType, String)] = [
        (.url, "Link"), (.image, "Image"), (.video, "Video"), (.text, "Note"), (.audio, "Audio"),
        (.pdf, "PDF"), (.file, "File"),
    ]
    private static let methods: [(CaptureMethod, String)] = [
        (.shareExtension, "Shared"), (.typedNote, "Typed note"), (.voiceRecording, "Recorded"),
    ]
    private static let buckets: [(SyncBucket, String)] = [
        (.notSynced, "Not synced yet"), (.synced, "Synced"), (.needsAttention, "Needs attention"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort") {
                    Picker("Sort", selection: $filters.sort) {
                        Text("Newest first").tag(LocalRepository.SortOrder.newestFirst)
                        Text("Oldest first").tag(LocalRepository.SortOrder.oldestFirst)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Date") {
                    Picker("Date", selection: dateChoice) {
                        Text("Any time").tag(DateChoice.any)
                        Text("Today").tag(DateChoice.today)
                        Text("Last 7 days").tag(DateChoice.last7)
                        Text("Last 30 days").tag(DateChoice.last30)
                        Text("Custom").tag(DateChoice.custom)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if case .custom = filters.date {
                        DatePicker("From", selection: customFrom, displayedComponents: .date)
                        DatePicker("To", selection: customThrough, displayedComponents: .date)
                    }
                }
                Section("Type") {
                    ForEach(Self.types, id: \.0) { type, title in
                        Toggle(title, isOn: membership(type, in: $filters.types))
                    }
                }
                Section("How it was saved") {
                    ForEach(Self.methods, id: \.0) { method, title in
                        Toggle(title, isOn: membership(method, in: $filters.methods))
                    }
                }
                Section("Other") {
                    Toggle("Has my comment", isOn: $filters.hasComment)
                    Toggle("Has location", isOn: $filters.hasLocation)
                }
                Section("Sync") {
                    ForEach(Self.buckets, id: \.0) { bucket, title in
                        Toggle(title, isOn: membership(bucket, in: $filters.sync))
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { filters = SheetFilters() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func membership<T: Hashable>(_ element: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(element) },
                set: { on in
                    if on { set.wrappedValue.insert(element) } else { set.wrappedValue.remove(element) }
                })
    }

    private var dateChoice: Binding<DateChoice> {
        Binding(get: {
            switch filters.date {
            case .any: .any
            case .today: .today
            case .last7: .last7
            case .last30: .last30
            case .custom: .custom
            }
        }, set: { choice in
            switch choice {
            case .any: filters.date = .any
            case .today: filters.date = .today
            case .last7: filters.date = .last7
            case .last30: filters.date = .last30
            case .custom:
                if case .custom = filters.date { return }
                let today = Date()
                filters.date = .custom(from: Calendar.current.date(byAdding: .day, value: -7, to: today) ?? today,
                                       through: today)
            }
        })
    }

    private var customFrom: Binding<Date> {
        Binding(get: { if case let .custom(from, _) = filters.date { from } else { Date() } },
                set: { if case let .custom(_, through) = filters.date { filters.date = .custom(from: $0, through: through) } })
    }

    private var customThrough: Binding<Date> {
        Binding(get: { if case let .custom(_, through) = filters.date { through } else { Date() } },
                set: { if case let .custom(from, _) = filters.date { filters.date = .custom(from: from, through: $0) } })
    }
}
