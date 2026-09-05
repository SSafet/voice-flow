import Cocoa

extension AppDelegate {
    func configureSourceWorkspace() {
        dataSourceStore = DataSourceStore()
        sourceCollector = SourceCollector(store: dataSourceStore)
        sourcesView = SourcesView(store: dataSourceStore, collector: sourceCollector)
        sourcesView.consumers = { [weak self] id in
            guard let self else { return [] }
            var links = AssistantsStore.shared.assistants.filter { $0.selectedSourceIDs.contains(id) }.map { assistant in
                SourceConsumerLink(title: "Assistant · " + assistant.name) { [weak self] in
                    self?.chatPanel.showSourceConsumer(.assistant(slug: assistant.slug))
                }
            }
            links += ((try? self.agentJobStore?.jobs(limit: 500)) ?? []).filter { $0.selectedSourceIDs.contains(id) }.map { job in
                SourceConsumerLink(title: "Automation · " + job.name) { [weak self] in
                    self?.chatPanel.showSourceConsumer(.automation(jobID: job.id))
                }
            }
            return links
        }
        sourcesView.onOpenSettings = { [weak self] in self?.chatPanel.showWorkspaceDestination(.settings) }
        chatPanel.setSourcesView(sourcesView)
        chatPanel.onSourcesSelected = { [weak self] in self?.sourcesView.refresh() }
        chatPanel.onSourcesBack = { [weak self] in self?.sourcesView.goBack() ?? false }
        chatPanel.setSettingsView(settingsWindow.makeWorkspaceView())
        chatPanel.onSettingsSelected = { [weak self] in self?.settingsWindow.prepareForPresentation() }
        dataSourceStore.onChange = { [weak self] in self?.sourcesView.refresh() }
        sourceCollector.start()
    }
    func agentDataSourceOptions() -> [SourceSelectionOption] {
        guard let dataSourceStore else { return [] }
        return dataSourceStore.listSources().map { source in
            let status = dataSourceStore.status(sourceID: source.id)
            let state = status.lastError != nil ? "Last collection failed" : status.lastSuccess == nil ? "Not collected yet" : "\(status.itemCount) collected items"
            return SourceSelectionOption(id: source.id, title: source.name, detail: "\(source.kind.title) · \(state)")
        }
    }
    func openAgentDataSources() { chatPanel.showSources() }
}
