workflow:
  phases:
    - id: 1
      name: HCNFoundationAndAzureRegistration
      display_name: "Phase 1 - HCN Foundation and Azure Registration"
      implemented: true
      requires_runner_profile: OperatorLaptop
      stages:
        - id: 1
          name: InputAndBuildValidation
          display_name: "1.1 Input and Build Validation"
          mode: Validate
          return_to_stage: 1
          max_attempts: 1
          retry_seconds: 0
          operations:
            - Test-EnvironmentConfiguration
            - Test-NamingConvention
            - Test-IPAddressAllocation
            - Test-RequiredSecrets
            - Test-ReleasePackageIntegrity

        - id: 2
          name: HardwareNetworkAndAzurePreflight
          display_name: "1.2 Hardware, Network, and Azure Preflight"
          mode: Validate
          requires_runner_profile: AutomationWorkstation
          return_to_stage: 1
          max_attempts: 3
          retry_seconds: 60
          operations:
            - Test-BootstrapNetwork
            - Find-iDRAC
            - Get-DellInventory
            - Test-HardwareReadiness
            - Test-NICState
            - Test-IPConfiguration
            - Test-Gateway
            - Test-DNS
            - Test-NTP
            - Test-RemoteManagement
            - Test-AzureConnectivity
            - Test-AzureGovEndpoints
            - Test-AzureLocalReadiness
            - Connect-Azure
            - Test-Subscription
            - Test-Permissions
            - Register-ResourceProviders
            - Test-ResourceGroup

        - id: 3
          name: HCNConfigurationAndArcRegistration
          display_name: "1.3 HCN Configuration and Arc Registration"
          mode: Apply
          requires_runner_profile: AutomationWorkstation
          requires_apply_confirmation: true
          return_to_stage: 2
          max_attempts: 1
          retry_seconds: 0
          operations:
            - Test-AzureLocalOS
            - Test-AzureLocalPolicyState
            - Set-NicRoleMapping
            - Set-ManagementNetwork
            - Set-DNS
            - Set-NTP
            - Enable-PowerShellRemoting
            - Install-RequiredModules
            - Set-HostName
            - Register-ArcNode

        - id: 4
          name: NodeAndArcValidation
          display_name: "1.4 Node and Arc Validation"
          mode: Validate
          requires_runner_profile: AutomationWorkstation
          return_to_stage: 3
          max_attempts: 2
          retry_seconds: 60
          operations:
            - Test-ArcRegistration
            - Test-NodeHealth
            - Test-ArcHealth

    - id: 2
      name: AzureLocalClusterDeployment
      display_name: "Phase 2 - Azure Local Cluster Deployment"
      implemented: false
      locked_until_phase: 1
      stages:
        - id: 1
          name: ClusterDeploymentInputValidation
          display_name: "2.1 Cluster Deployment Input Validation"
          mode: Validate
          operations: []

        - id: 2
          name: AzureLocalClusterDeployment
          display_name: "2.2 Azure Local Cluster Deployment"
          mode: Apply
          operations: []

        - id: 3
          name: ClusterAndStorageValidation
          display_name: "2.3 Cluster and Storage Validation"
          mode: Validate
          operations: []

    - id: 3
      name: AzureLocalServices
      display_name: "Phase 3 - Azure Local Services"
      implemented: false
      locked_until_phase: 2
      stages:
        - id: 1
          name: ArcResourceBridgeConfiguration
          display_name: "3.1 Arc Resource Bridge Configuration"
          mode: Apply
          operations: []

        - id: 2
          name: CustomLocationConfiguration
          display_name: "3.2 Custom Location Configuration"
          mode: Apply
          operations: []

        - id: 3
          name: StorageAndLogicalNetworkConfiguration
          display_name: "3.3 Storage and Logical Network Configuration"
          mode: Apply
          operations: []

        - id: 4
          name: ServicesValidation
          display_name: "3.4 Services Validation"
          mode: Validate
          operations: []

    - id: 4
      name: OperationalValidationAndCertification
      display_name: "Phase 4 - Operational Validation and Certification"
      implemented: false
      locked_until_phase: 3
      stages:
        - id: 1
          name: TestWorkloadDeployment
          display_name: "4.1 Test Workload Deployment"
          mode: Apply
          operations: []

        - id: 2
          name: WorkloadNetworkValidation
          display_name: "4.2 Workload Network Validation"
          mode: Validate
          operations: []

        - id: 3
          name: WorkloadCleanup
          display_name: "4.3 Workload Cleanup"
          mode: Apply
          operations: []

        - id: 4
          name: Certification
          display_name: "4.4 Certification"
          mode: Validate
          operations: []

## Current Remediation Model

Legacy imperative `Set-*` remediation scripts were superseded by idempotent `Ensure-*` adapters. Current adapters validate desired state, skip compliant settings, request approval before disruptive changes, and block mutation on existing or registered Azure Local clusters.