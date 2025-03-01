Feature: Tuist dependencies.

    Scenario: The project is an application with Carthage Dependencies.swift (app_with_carthage_dependencies)
        Given that tuist is available
        And I have a working directory
        Then I copy the fixture app_with_spm_dependencies into the working directory
        Then tuist fetches dependencies
        Then tuist builds the scheme AppTests from the project

    Scenario: The project is an application with SPM Dependencies.swift (app_with_spm_dependencies)
        Given that tuist is available
        And I have a working directory
        Then I copy the fixture app_with_spm_dependencies into the working directory
        Then tuist fetches dependencies
        Then tuist builds the scheme AppTests from the project
