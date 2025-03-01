import Foundation
import RxBlocking
import RxSwift
import TSCBasic
import TuistAutomation
import TuistCache
import TuistCloud
import TuistCore
import TuistGenerator
import TuistGraph
import TuistLoader
import TuistSupport

/// A provider that concatenates the default mappers, to the mapper that adds the build phase
/// to locate the built products directory.
class CacheControllerProjectMapperProvider: ProjectMapperProviding {
    fileprivate let contentHasher: ContentHashing
    init(contentHasher: ContentHashing) {
        self.contentHasher = contentHasher
    }

    func mapper(config: Config) -> ProjectMapping {
        let defaultProjectMapperProvider = ProjectMapperProvider(contentHasher: contentHasher)
        let defaultMapper = defaultProjectMapperProvider.mapper(
            config: config
        )
        return SequentialProjectMapper(mappers: [defaultMapper])
    }
}

protocol CacheControllerProjectGeneratorProviding {
    /// Returns an instance of the project generator that should be used to generate the projects for caching.
    /// - Returns: An instance of the project generator.
    func generator() -> Generating
}

/// A provider that returns the project generator that should be used by the cache controller.
class CacheControllerProjectGeneratorProvider: CacheControllerProjectGeneratorProviding {
    fileprivate let contentHasher: ContentHashing
    init(contentHasher: ContentHashing) {
        self.contentHasher = contentHasher
    }

    func generator() -> Generating {
        let contentHasher = CacheContentHasher()
        let projectMapperProvider = CacheControllerProjectMapperProvider(contentHasher: contentHasher)
        let workspaceMapperProvider = WorkspaceMapperProvider(projectMapperProvider: projectMapperProvider)
        return Generator(
            projectMapperProvider: projectMapperProvider,
            graphMapperProvider: GraphMapperProvider(),
            workspaceMapperProvider: workspaceMapperProvider,
            manifestLoaderFactory: ManifestLoaderFactory()
        )
    }
}

protocol CacheControlling {
    /// Caches the cacheable targets that are part of the workspace or project at the given path.
    /// - Parameters:
    ///   - path: Path to the directory that contains a workspace or a project.
    ///   - cacheProfile: The caching profile.
    ///   - targets: If present, a list of target to build.
    ///   - dependenciesOnly: If true, the targets passed in the `targets` parameter are not cached, but only their dependencies
    func cache(path: AbsolutePath, cacheProfile: TuistGraph.Cache.Profile, targetsToFilter: [String], dependenciesOnly: Bool) throws
}

final class CacheController: CacheControlling {
    /// Project generator provider.
    let projectGeneratorProvider: CacheControllerProjectGeneratorProviding

    /// Utility to build the (xc)frameworks.
    private let artifactBuilder: CacheArtifactBuilding

    private let bundleArtifactBuilder: CacheArtifactBuilding

    /// Cache graph content hasher.
    private let cacheGraphContentHasher: CacheGraphContentHashing

    /// Cache.
    private let cache: CacheStoring

    /// Cache graph linter.
    private let cacheGraphLinter: CacheGraphLinting

    convenience init(cache: CacheStoring,
                     artifactBuilder: CacheArtifactBuilding,
                     bundleArtifactBuilder: CacheArtifactBuilding,
                     contentHasher: ContentHashing)
    {
        self.init(
            cache: cache,
            artifactBuilder: artifactBuilder,
            bundleArtifactBuilder: bundleArtifactBuilder,
            projectGeneratorProvider: CacheControllerProjectGeneratorProvider(contentHasher: contentHasher),
            cacheGraphContentHasher: CacheGraphContentHasher(contentHasher: contentHasher),
            cacheGraphLinter: CacheGraphLinter()
        )
    }

    init(cache: CacheStoring,
         artifactBuilder: CacheArtifactBuilding,
         bundleArtifactBuilder: CacheArtifactBuilding,
         projectGeneratorProvider: CacheControllerProjectGeneratorProviding,
         cacheGraphContentHasher: CacheGraphContentHashing,
         cacheGraphLinter: CacheGraphLinting)
    {
        self.cache = cache
        self.projectGeneratorProvider = projectGeneratorProvider
        self.artifactBuilder = artifactBuilder
        self.bundleArtifactBuilder = bundleArtifactBuilder
        self.cacheGraphContentHasher = cacheGraphContentHasher
        self.cacheGraphLinter = cacheGraphLinter
    }

    func cache(path: AbsolutePath, cacheProfile: TuistGraph.Cache.Profile, targetsToFilter: [String], dependenciesOnly: Bool) throws {
        let generator = projectGeneratorProvider.generator()
        let (projectPath, graph) = try generator.generateWithGraph(path: path, projectOnly: false)

        // Lint
        cacheGraphLinter.lint(graph: graph)

        // Hash
        logger.notice("Hashing cacheable targets")

        let hashesByTargetToBeCached = try makeHashesByTargetToBeCached(
            for: graph,
            cacheProfile: cacheProfile,
            targetsToFilter: targetsToFilter,
            dependenciesOnly: dependenciesOnly
        )

        logger.notice("Building cacheable targets")

        for (index, (target, hash)) in hashesByTargetToBeCached.enumerated() {
            logger.notice("Building cacheable targets: \(target.target.name), \(index + 1) out of \(hashesByTargetToBeCached.count)")

            // Build
            try buildAndCacheArtifact(
                path: projectPath,
                target: target,
                configuration: cacheProfile.configuration,
                hash: hash
            )
        }

        logger.notice("All cacheable targets have been cached successfully as \(artifactBuilder.cacheOutputType.description)s", metadata: .success)
    }

    /// Builds and caches the artifact
    /// - Parameters:
    ///   - path: Path to either the .xcodeproj or .xcworkspace that contains the artifact to be cached
    ///   - target: Target whose product will be built and cached.
    ///   - configuration: The configuration
    ///   - hash: Hash of the target.
    private func buildAndCacheArtifact(path: AbsolutePath,
                                       target: GraphTarget,
                                       configuration: String,
                                       hash: String) throws
    {
        let builder: CacheArtifactBuilding
        if target.target.product == .bundle {
            builder = bundleArtifactBuilder
        } else {
            builder = artifactBuilder
        }

        try FileHandler.shared.inTemporaryDirectory { outputDirectory in
            try builder.build(
                projectTarget: XcodeBuildTarget(with: path),
                target: target.target,
                configuration: configuration,
                into: outputDirectory
            )

            _ = try cache.store(
                hash: hash,
                paths: FileHandler.shared.glob(outputDirectory, glob: "*")
            ).toBlocking().last()
        }
    }

    func makeHashesByTargetToBeCached(
        for graph: Graph,
        cacheProfile: TuistGraph.Cache.Profile,
        targetsToFilter: [String],
        dependenciesOnly: Bool
    ) throws -> [(GraphTarget, String)] {
        let hashesByCacheableTarget = try cacheGraphContentHasher.contentHashes(
            for: graph,
            cacheProfile: cacheProfile,
            cacheOutputType: artifactBuilder.cacheOutputType
        )

        let graphTraverser = GraphTraverser(graph: graph)
        let filteredTargets = graphTraverser.allTargets().filter { targetsToFilter.isEmpty ? true : targetsToFilter.contains($0.target.name) }

        return try topologicalSort(
            Array(filteredTargets),
            successors: {
                Array(graphTraverser.directTargetDependencies(path: $0.path, name: $0.target.name))
            }
        )
        .filter { target in
            guard let hash = hashesByCacheableTarget[target] else { return false }
            let cacheExists = try cache.exists(hash: hash).toBlocking().first() ?? false
            if cacheExists {
                logger.pretty("The target \(.bold(.raw(target.target.name))) with hash \(.bold(.raw(hash))) and type \(artifactBuilder.cacheOutputType.description) is already in the cache. Skipping...")
            }
            return !cacheExists
        }
        .filter {
            return !dependenciesOnly || !targetsToFilter.contains($0.target.name)
        }
        .reversed()
        .map { ($0, hashesByCacheableTarget[$0]!) }
    }
}
