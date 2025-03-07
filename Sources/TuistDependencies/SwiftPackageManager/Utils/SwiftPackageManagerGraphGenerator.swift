import Foundation
import ProjectDescription
import TSCBasic
import TSCUtility
import TuistCore
import TuistGraph
import TuistSupport

// MARK: - Swift Package Manager Graph Generator Errors

enum SwiftPackageManagerGraphGeneratorError: FatalError, Equatable {
    /// Thrown when `SwiftPackageManagerWorkspaceState.Dependency.Kind` is not one of the expected values.
    case unsupportedDependencyKind(String)
    /// Thrown when `SwiftPackageManagerWorkspaceState.packageRef.path` is not present in a local swift package.
    case missingPathInLocalSwiftPackage(String)

    /// Error type.
    var type: ErrorType {
        switch self {
        case .unsupportedDependencyKind, .missingPathInLocalSwiftPackage:
            return .bug
        }
    }

    /// Error description.
    var description: String {
        switch self {
        case let .unsupportedDependencyKind(name):
            return "The dependency kind \(name) is not supported."
        case let .missingPathInLocalSwiftPackage(name):
            return "The local package \(name) does not contain the path in the generated `workspace-state.json` file."
        }
    }
}

// MARK: - Swift Package Manager Graph Generator

/// A protocol that defines an interface to generate the `DependenciesGraph` for the `SwiftPackageManager` dependencies.
public protocol SwiftPackageManagerGraphGenerating {
    /// Generates the `DependenciesGraph` for the `SwiftPackageManager` dependencies.
    /// - Parameter path: The path to the directory that contains the `checkouts` directory where `SwiftPackageManager` installed dependencies.
    /// - Parameter productTypes: The custom `Product` types to be used for SPM targets.
    /// - Parameter platforms: The supported platforms.
    /// - Parameter deploymentTargets: The configured deployment targets.
    /// - Parameter swiftToolsVersion: The version of Swift tools that will be used to generate dependencies.
    func generate(
        at path: AbsolutePath,
        productTypes: [String: TuistGraph.Product],
        platforms: Set<TuistGraph.Platform>,
        deploymentTargets: Set<TuistGraph.DeploymentTarget>,
        swiftToolsVersion: TSCUtility.Version?
    ) throws -> TuistCore.DependenciesGraph
}

public final class SwiftPackageManagerGraphGenerator: SwiftPackageManagerGraphGenerating {
    private let swiftPackageManagerController: SwiftPackageManagerControlling
    private let packageInfoMapper: PackageInfoMapping

    public init(
        swiftPackageManagerController: SwiftPackageManagerControlling = SwiftPackageManagerController(),
        packageInfoMapper: PackageInfoMapping = PackageInfoMapper()
    ) {
        self.swiftPackageManagerController = swiftPackageManagerController
        self.packageInfoMapper = packageInfoMapper
    }

    // swiftlint:disable:next function_body_length
    public func generate(
        at path: AbsolutePath,
        productTypes: [String: TuistGraph.Product],
        platforms: Set<TuistGraph.Platform>,
        deploymentTargets: Set<TuistGraph.DeploymentTarget>,
        swiftToolsVersion: TSCUtility.Version?
    ) throws -> TuistCore.DependenciesGraph {
        let artifactsFolder = path.appending(component: "artifacts")
        let checkoutsFolder = path.appending(component: "checkouts")
        let workspacePath = path.appending(component: "workspace-state.json")

        let workspaceState = try JSONDecoder().decode(SwiftPackageManagerWorkspaceState.self, from: try FileHandler.shared.readFile(workspacePath))
        let packageInfos: [(name: String, folder: AbsolutePath, info: PackageInfo)]
        packageInfos = try workspaceState.object.dependencies.map { dependency in
            let name = dependency.packageRef.name
            let packageFolder: AbsolutePath
            switch dependency.packageRef.kind {
            case "remote":
                packageFolder = checkoutsFolder.appending(component: dependency.subpath)
            case "local":
                guard let path = dependency.packageRef.path else {
                    throw SwiftPackageManagerGraphGeneratorError.missingPathInLocalSwiftPackage(name)
                }
                packageFolder = AbsolutePath(path)
            default:
                throw SwiftPackageManagerGraphGeneratorError.unsupportedDependencyKind(dependency.packageRef.kind)
            }

            let packageInfo = try swiftPackageManagerController.loadPackageInfo(at: packageFolder)
            return (
                name: name,
                folder: packageFolder,
                info: packageInfo
            )
        }

        let productToPackage: [String: String] = packageInfos.reduce(into: [:]) { result, packageInfo in
            packageInfo.info.products.forEach { result[$0.name] = packageInfo.name }
        }

        let packageToProject = Dictionary(uniqueKeysWithValues: packageInfos.map { ($0.name, $0.folder) })
        let packageInfoDictionary = Dictionary(uniqueKeysWithValues: packageInfos.map { ($0.name, $0.info) })
        let packageToFolder = Dictionary(uniqueKeysWithValues: packageInfos.map { ($0.name, $0.folder) })

        let (targetToProducts, targetToResolvedDependencies, externalDependencies) = try packageInfoMapper.preprocess(
            packageInfos: packageInfoDictionary,
            productToPackage: productToPackage,
            packageToFolder: packageToFolder,
            artifactsFolder: artifactsFolder
        )

        let externalProjects: [Path: ProjectDescription.Project] = try packageInfos.reduce(into: [:]) { result, packageInfo in
            let manifest = try packageInfoMapper.map(
                packageInfo: packageInfo.info,
                packageInfos: packageInfoDictionary,
                name: packageInfo.name,
                path: packageInfo.folder,
                productTypes: productTypes,
                platforms: platforms,
                deploymentTargets: deploymentTargets,
                targetToProducts: targetToProducts,
                targetToResolvedDependencies: targetToResolvedDependencies,
                packageToProject: packageToProject,
                swiftToolsVersion: swiftToolsVersion
            )
            result[Path(packageInfo.folder.pathString)] = manifest
        }

        return DependenciesGraph(externalDependencies: externalDependencies, externalProjects: externalProjects)
    }
}
