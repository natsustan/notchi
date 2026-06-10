import Foundation
import XCTest
@testable import notchi

private struct ResolverProcessCall: Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]?
}

@MainActor
final class ClaudeCLIResolverTests: XCTestCase {
    override func tearDown() {
        ClaudeConfigDirectoryResolver.resetTestingHooks()
        ClaudeCLIResolver.resetTestingHooks()
        super.tearDown()
    }

    func testClaudeConfigDirectoryResolverUsesProcessEnvironment() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in
                XCTFail("Shell probing should not run when the environment already provides CLAUDE_CONFIG_DIR")
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/claude-config")
        XCTAssertEqual(resolution.source, .environment)
    }

    func testClaudeConfigDirectoryResolverFallsBackToShell() {
        var processCalls: [[String]] = []
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                if arguments == ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "/tmp/from-shell\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/from-shell")
        XCTAssertEqual(resolution.source, .shell)
        XCTAssertEqual(processCalls, [["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""]])
    }

    func testClaudeConfigDirectoryResolverExtractsPathFromNoisyShellOutput() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                if arguments == ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "/tmp/plugin-warning-path\n/tmp/from-shell\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertEqual(resolution.path, "/tmp/from-shell")
        XCTAssertEqual(resolution.source, .shell)
    }

    func testClaudeConfigDirectoryResolverDoesNotCacheFallbackResults() {
        let scenarios: [(name: String, probeOutputs: [String?])] = [
            ("both probes fail", [nil, nil, "/tmp/from-shell\n"]),
            ("login probe unset then interactive probe fails", ["\n", nil, "\n", "/tmp/from-shell\n"]),
        ]

        for (name, probeOutputs) in scenarios {
            var probeCall = 0
            ClaudeConfigDirectoryResolver.resetTestingHooks()
            ClaudeConfigDirectoryResolver.testHooks = .init(
                environment: { ["SHELL": "/mock/zsh"] },
                isExecutableFile: { path in
                    path == "/mock/zsh"
                },
                runProcess: { _, arguments, _ in
                    guard arguments == ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] ||
                        arguments == ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] else {
                        return nil
                    }

                    defer { probeCall += 1 }
                    return probeCall < probeOutputs.count ? probeOutputs[probeCall] : nil
                }
            )

            let firstResolution = ClaudeConfigDirectoryResolver.resolve()
            let secondResolution = ClaudeConfigDirectoryResolver.resolve()

            XCTAssertEqual(firstResolution.source, .fallback, name)
            XCTAssertEqual(secondResolution.path, "/tmp/from-shell", name)
            XCTAssertEqual(secondResolution.source, .shell, name)
        }
    }

    func testClaudeConfigDirectoryResolverCachesVerifiedDefaultFallbackResults() {
        var processCalls: [[String]] = []
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                return "\n"
            }
        )

        let firstResolution = ClaudeConfigDirectoryResolver.resolve()
        let secondResolution = ClaudeConfigDirectoryResolver.resolve()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(firstResolution.path, "\(home)/.claude")
        XCTAssertEqual(firstResolution.source, .fallback)
        XCTAssertEqual(secondResolution.path, "\(home)/.claude")
        XCTAssertEqual(secondResolution.source, .fallback)
        XCTAssertEqual(processCalls, [["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""], ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""]])
    }

    func testClaudeConfigDirectoryResolverFallsBackToInteractiveShell() {
        var processCalls: [[String]] = []
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                if arguments == ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""] {
                    return "~/custom-claude\n"
                }
                return nil
            }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()

        XCTAssertTrue(resolution.path.hasSuffix("/custom-claude"))
        XCTAssertEqual(resolution.source, .shell)
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "printf '%s' \"$CLAUDE_CONFIG_DIR\""],
                ["-ic", "printf '%s' \"$CLAUDE_CONFIG_DIR\""],
            ]
        )
    }

    func testClaudeConfigDirectoryResolverFallsBackToDefaultDirectory() {
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        let resolution = ClaudeConfigDirectoryResolver.resolve()
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(resolution.path, "\(home)/.claude")
        XCTAssertEqual(resolution.source, .fallback)
    }

    func testResolveUserAgentUsesClaudeBinaryFromResolvedConfigDirectory() {
        let claudePath = "/tmp/custom-claude/bin/claude"
        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/custom-claude"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        var processCalls: [(String, [String])] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append((executablePath, arguments))
                return "2.1.92 (Claude Code)\n"
            }
        )

        let userAgent = ClaudeCLIResolver.resolveUserAgent()

        XCTAssertEqual(userAgent, "claude-code/2.1.92")
        XCTAssertEqual(processCalls.count, 1)
        XCTAssertEqual(processCalls.first?.0, claudePath)
        XCTAssertEqual(processCalls.first?.1, ["--version"])
    }

    func testLiveUserAgentResolutionRunsOffMainThread() async {
        final class ThreadRecorder: @unchecked Sendable {
            var sawMainThread: Bool?
        }

        ClaudeConfigDirectoryResolver.testHooks = .init(
            environment: { ["CLAUDE_CONFIG_DIR": "/tmp/claude-config"] },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        let recorder = ThreadRecorder()
        ClaudeCLIResolver.testHooks = .init(
            environment: {
                recorder.sawMainThread = Thread.isMainThread
                return [:]
            },
            isExecutableFile: { _ in false },
            runProcess: { _, _, _ in nil }
        )

        let userAgent = await ClaudeUsageServiceDependencies.live.resolveUserAgent()

        XCTAssertNil(userAgent)
        XCTAssertEqual(recorder.sawMainThread, false)
    }

    func testShellResolverUsesLoginShellResultWithoutInteractiveFallback() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                XCTAssertEqual(executablePath, "/mock/zsh")
                processCalls.append(arguments)
                if arguments == ["-lc", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(processCalls, [["-lc", "command -v claude"]])
    }

    func testShellResolverFallsBackToInteractiveShellWhenLoginShellMisses() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                XCTAssertEqual(executablePath, "/mock/zsh")
                processCalls.append(arguments)
                if arguments == ["-ic", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "command -v claude"],
                ["-ic", "command -v claude"],
            ]
        )
    }

    func testShellResolverIgnoresShellNoiseBeforeExecutablePath() {
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh" || path == "/resolved/claude"
            },
            runProcess: { _, arguments, _ in
                if arguments == ["-lc", "command -v claude"] {
                    return "nvm initialized\n /resolved/claude \n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
    }

    func testShellResolverReturnsNilWhenNeitherModeFindsExecutablePath() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/mock/zsh"
            },
            runProcess: { _, arguments, _ in
                processCalls.append(arguments)
                return "claude not found\n"
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: ["SHELL": "/mock/zsh"])

        XCTAssertNil(resolvedPath)
        XCTAssertEqual(
            processCalls,
            [
                ["-lc", "command -v claude"],
                ["-ic", "command -v claude"],
            ]
        )
    }

    func testShellResolverFallsBackToDefaultShellsWhenSHELLIsUnset() {
        var processCalls: [[String]] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { [:] },
            isExecutableFile: { path in
                path == "/bin/zsh" || path == "/bin/bash" || path == "/resolved/claude"
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append([executablePath] + arguments)
                if executablePath == "/bin/bash", arguments == ["-lc", "command -v claude"] {
                    return "/resolved/claude\n"
                }
                return nil
            }
        )

        let resolvedPath = ClaudeCLIResolver.resolveCommandPathViaShell(environment: [:])

        XCTAssertEqual(resolvedPath, "/resolved/claude")
        XCTAssertEqual(
            processCalls,
            [
                ["/bin/zsh", "-lc", "command -v claude"],
                ["/bin/zsh", "-ic", "command -v claude"],
                ["/bin/bash", "-lc", "command -v claude"],
            ]
        )
    }

    func testResolveUserAgentUsesClaudeFromPATHBeforeShellFallback() {
        var processCalls: [(String, [String])] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/mock/bin"] },
            isExecutableFile: { path in
                path == "/mock/bin/claude"
            },
            runProcess: { executablePath, arguments, _ in
                processCalls.append((executablePath, arguments))
                XCTAssertEqual(executablePath, "/mock/bin/claude")
                XCTAssertEqual(arguments, ["--version"])
                return "2.1.89 (Claude Code)\n"
            }
        )

        let userAgent = ClaudeCLIResolver.resolveUserAgent()

        XCTAssertEqual(userAgent, "claude-code/2.1.89")
        XCTAssertEqual(processCalls.count, 1)
    }

    func testResolveVersionInjectsResolvedClaudeDirectoryIntoPATH() {
        let claudePath = "/mock/nvm/bin/claude"
        var receivedEnvironment: [String: String]?
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin"] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, environment in
                XCTAssertEqual(executablePath, claudePath)
                XCTAssertEqual(arguments, ["--version"])
                receivedEnvironment = environment
                return "2.1.89 (Claude Code)\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(receivedEnvironment?["PATH"], "/mock/nvm/bin:/usr/bin:/bin")
    }

    func testResolveVersionWorksForNativeBinaryInstall() {
        let claudePath = "/opt/homebrew/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin"] },
            isExecutableFile: { path in
                path == claudePath
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                return "2.1.89 (Claude Code)\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
                ),
            ]
        )
    }

    func testResolveVersionFallsBackToInteractiveShellAfterDirectAndLoginShellMiss() {
        let claudePath = "/mock/nvm/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin", "SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == claudePath || path == "/mock/zsh"
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                if executablePath == "/mock/zsh", arguments == ["-ic", "\"$1\" --version", "zsh", claudePath] {
                    return "nvm initialized\n2.1.89 (Claude Code)\n"
                }
                return nil
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertEqual(version, "2.1.89")
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-lc", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-ic", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
            ]
        )
    }

    func testExtractVersionIgnoresShellNoiseAndReturnsFirstVersionLine() {
        let version = ClaudeCLIResolver.extractVersion(
            from: """
            nvm initialized
            export PATH=/mock/nvm/bin:$PATH
            2.1.89 (Claude Code)
            """
        )

        XCTAssertEqual(version, "2.1.89")
    }

    func testResolveVersionReturnsNilWhenDirectAndShellProbesDoNotYieldVersion() {
        let claudePath = "/mock/nvm/bin/claude"
        var processCalls: [ResolverProcessCall] = []
        ClaudeCLIResolver.testHooks = .init(
            environment: { ["PATH": "/usr/bin:/bin", "SHELL": "/mock/zsh"] },
            isExecutableFile: { path in
                path == claudePath || path == "/mock/zsh"
            },
            runProcess: { executablePath, arguments, environment in
                processCalls.append(
                    ResolverProcessCall(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                )
                if executablePath == claudePath {
                    return "claude version lookup failed\n"
                }
                return "nvm initialized\n"
            }
        )

        let version = ClaudeCLIResolver.resolveVersion(at: claudePath)

        XCTAssertNil(version)
        XCTAssertEqual(
            processCalls,
            [
                ResolverProcessCall(
                    executablePath: claudePath,
                    arguments: ["--version"],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-lc", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
                ResolverProcessCall(
                    executablePath: "/mock/zsh",
                    arguments: ["-ic", "\"$1\" --version", "zsh", claudePath],
                    environment: ["PATH": "/mock/nvm/bin:/usr/bin:/bin", "SHELL": "/mock/zsh"]
                ),
            ]
        )
    }
}
