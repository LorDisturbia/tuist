import Foundation
import TSCBasic
import TuistCore
import TuistSupport

public protocol ManifestFilesLocating: AnyObject {
    /// It locates the manifest files in the locating directory.
    /// - Parameter locatingPath: Directory for which the manifest files will be obtained.
    func locateManifests(at locatingPath: AbsolutePath) -> [(Manifest, AbsolutePath)]

    /// It locates all plugin manifest files under the the root directory (as defined in `RootDirectoryLocator`).
    /// - Parameters:
    ///     - locatingPath: Directory for which the **plugin** manifest files will be obtained.
    ///     - onlyCurrentDirectory: If true, search for plugin manifests only in the directory of `locatingPath`
    func locatePluginManifests(
        at locatingPath: AbsolutePath,
        onlyCurrentDirectory: Bool
    ) -> [AbsolutePath]

    /// It locates all project and workspace manifest files under the root directory (as defined in `RootDirectoryLocator`).
    /// - Parameters:
    ///     - locatingPath: Directory for which the **project** and **workspace** manifest files will be obtained.
    ///     - onlyCurrentDirectory: If true, search for manifests only in the directory of `locatingPath`
    func locateProjectManifests(
        at locatingPath: AbsolutePath,
        onlyCurrentDirectory: Bool
    ) -> [ManifestFilesLocator.ProjectManifest]

    /// It traverses up the directory hierarchy until it finds a `Config.swift` file.
    /// - Parameter locatingPath: Path from where to do the lookup.
    func locateConfig(at locatingPath: AbsolutePath) -> AbsolutePath?

    /// It traverses up the directory hierarchy until it finds a `Dependencies.swift` file.
    /// - Parameter locatingPath: Path from where to do the lookup.
    func locateDependencies(at locatingPath: AbsolutePath) -> AbsolutePath?

    /// It traverses up the directory hierarchy until it finds a `Setup.swift` file.
    /// - Parameter locatingPath: Path from where to do the lookup.
    func locateSetup(at locatingPath: AbsolutePath) -> AbsolutePath?
}

public final class ManifestFilesLocator: ManifestFilesLocating {
    /// Utility to locate the root directory of the project
    let rootDirectoryLocator: RootDirectoryLocating

    public init(rootDirectoryLocator: RootDirectoryLocating = RootDirectoryLocator()) {
        self.rootDirectoryLocator = rootDirectoryLocator
    }

    public func locateManifests(at locatingPath: AbsolutePath) -> [(Manifest, AbsolutePath)] {
        Manifest.allCases.compactMap { manifest in
            let path = locatingPath.appending(component: manifest.fileName(locatingPath))
            if FileHandler.shared.exists(path) { return (manifest, path) }
            return nil
        }
    }

    public func locatePluginManifests(
        at locatingPath: AbsolutePath,
        onlyCurrentDirectory: Bool
    ) -> [AbsolutePath] {
        if onlyCurrentDirectory {
            let pluginPath = locatingPath.appending(
                component: Manifest.plugin.fileName(locatingPath)
            )
            guard FileHandler.shared.exists(pluginPath) else { return [] }
            return [pluginPath]
        } else {
            guard let rootPath = rootDirectoryLocator.locate(from: locatingPath) else {
                return FileHandler.shared.glob(locatingPath, glob: "**/\(Manifest.plugin.fileName(locatingPath))")
            }
            return FileHandler.shared.glob(rootPath, glob: "**/\(Manifest.plugin.fileName(rootPath))")
        }
    }

    /// Project manifest returned by `locateProjectManifests`
    public struct ProjectManifest: Equatable {
        public let manifest: Manifest
        public let path: AbsolutePath

        public init(
            manifest: Manifest,
            path: AbsolutePath
        ) {
            self.manifest = manifest
            self.path = path
        }
    }

    public func locateProjectManifests(
        at locatingPath: AbsolutePath,
        onlyCurrentDirectory: Bool
    ) -> [ProjectManifest] {
        if onlyCurrentDirectory {
            return [
                ProjectManifest(
                    manifest: Manifest.project,
                    path: locatingPath.appending(
                        component: Manifest.project.fileName(locatingPath)
                    )
                ),
                ProjectManifest(
                    manifest: Manifest.workspace,
                    path: locatingPath.appending(
                        component: Manifest.workspace.fileName(locatingPath)
                    )
                ),
            ]
            .filter { FileHandler.shared.exists($0.path) }
        } else {
            guard let rootPath = rootDirectoryLocator.locate(from: locatingPath) else {
                let projectsPaths = FileHandler.shared.glob(locatingPath, glob: "**/\(Manifest.project.fileName(locatingPath))")
                    .map {
                        ProjectManifest(
                            manifest: Manifest.project,
                            path: $0
                        )
                    }
                let workspacesPaths = FileHandler.shared.glob(locatingPath, glob: "**/\(Manifest.workspace.fileName(locatingPath))")
                    .map {
                        ProjectManifest(
                            manifest: Manifest.workspace,
                            path: $0
                        )
                    }
                return projectsPaths + workspacesPaths
            }

            let projectsPaths = FileHandler.shared.glob(rootPath, glob: "**/\(Manifest.project.fileName(rootPath))")
                .map {
                    ProjectManifest(
                        manifest: Manifest.project,
                        path: $0
                    )
                }
            let workspacesPaths = FileHandler.shared.glob(rootPath, glob: "**/\(Manifest.workspace.fileName(rootPath))")
                .map {
                    ProjectManifest(
                        manifest: Manifest.workspace,
                        path: $0
                    )
                }
            return projectsPaths + workspacesPaths
        }
    }

    public func locateConfig(at locatingPath: AbsolutePath) -> AbsolutePath? {
        let subPath = RelativePath("\(Constants.tuistDirectoryName)/\(Manifest.config.fileName(locatingPath))")
        return traverseAndLocate(at: locatingPath, appending: subPath)
    }

    public func locateDependencies(at locatingPath: AbsolutePath) -> AbsolutePath? {
        let subPath = RelativePath("\(Constants.tuistDirectoryName)/\(Manifest.dependencies.fileName(locatingPath))")
        return traverseAndLocate(at: locatingPath, appending: subPath)
    }

    public func locateSetup(at locatingPath: AbsolutePath) -> AbsolutePath? {
        let subPath = RelativePath(Manifest.setup.fileName(locatingPath))
        return traverseAndLocate(at: locatingPath, appending: subPath)
    }

    // MARK: - Helpers

    private func traverseAndLocate(at locatingPath: AbsolutePath, appending subpath: RelativePath) -> AbsolutePath? {
        let manifestPath = locatingPath.appending(subpath)

        if FileHandler.shared.exists(manifestPath) {
            return manifestPath
        } else if locatingPath != .root {
            return traverseAndLocate(at: locatingPath.parentDirectory, appending: subpath)
        } else {
            return nil
        }
    }
}
