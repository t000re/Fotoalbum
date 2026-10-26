import SwiftUI

/// «Åpne prosjekt»: alle prosjektene, sist endret først. Det åpne er huket av.
struct ProjectsMenu: View {
    let model: AppModel

    var body: some View {
        Menu("Åpne prosjekt") {
            ForEach(model.listProjects()) { p in
                Button {
                    model.openProject(p.id)
                } label: {
                    if p.id == model.projectID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        }
    }
}
