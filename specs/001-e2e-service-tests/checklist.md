# Implementation Checklist: E2E Service Tests

**Purpose**: Verify all E2E test components are properly implemented and functional
**Created**: 2025-12-15
**Feature**: [spec.md](./spec.md)

## Test Infrastructure

- [ ] CHK001 Create `e2e_test/` directory structure
- [ ] CHK002 Create `e2e_test/test_helper.exs` with ExUnit setup
- [ ] CHK003 Create shared E2E helper module (`E2ETest.Helper`)
- [ ] CHK004 Create mix alias `test.e2e` in umbrella `mix.exs`
- [ ] CHK005 Create mix alias `test.e2e.dns` in umbrella `mix.exs`
- [ ] CHK006 Create mix alias `test.e2e.mdns` in umbrella `mix.exs`
- [ ] CHK007 Create mix alias `test.e2e.dhcpv4` in umbrella `mix.exs`
- [ ] CHK008 Create mix alias `test.e2e.dhcpv6` in umbrella `mix.exs`

## DNS E2E Tests

- [ ] CHK009 Create `e2e_test/dns_e2e_test.exs` test file
- [ ] CHK010 Test DNS server startup on non-privileged port
- [ ] CHK011 Test A record query and response
- [ ] CHK012 Test NXDOMAIN response for non-existent domains
- [ ] CHK013 Test DNS server cleanup after test completion
- [ ] CHK014 Verify DNS E2E test passes locally

## mDNS E2E Tests

- [ ] CHK015 Create `e2e_test/mdns_e2e_test.exs` test file
- [ ] CHK016 Test mDNS server startup
- [ ] CHK017 Test service registration
- [ ] CHK018 Test PTR query for service type
- [ ] CHK019 Test SRV record response
- [ ] CHK020 Test mDNS server cleanup after test completion
- [ ] CHK021 Verify mDNS E2E test passes locally

## DHCPv4 E2E Tests

- [ ] CHK022 Create `e2e_test/dhcpv4_e2e_test.exs` test file
- [ ] CHK023 Test DHCPv4 server startup on non-privileged port
- [ ] CHK024 Test DHCP DISCOVER → OFFER handshake
- [ ] CHK025 Test DHCP REQUEST → ACK handshake
- [ ] CHK026 Test lease recording after ACK
- [ ] CHK027 Test DHCPv4 server cleanup after test completion
- [ ] CHK028 Verify DHCPv4 E2E test passes locally

## DHCPv6 E2E Tests

- [ ] CHK029 Create `e2e_test/dhcpv6_e2e_test.exs` test file
- [ ] CHK030 Test DHCPv6 server startup on non-privileged port
- [ ] CHK031 Test SOLICIT → ADVERTISE handshake
- [ ] CHK032 Test REQUEST → REPLY handshake
- [ ] CHK033 Test lease recording after REPLY
- [ ] CHK034 Test DHCPv6 server cleanup after test completion
- [ ] CHK035 Verify DHCPv6 E2E test passes locally

## GitHub Actions Integration

- [ ] CHK036 Create `.github/workflows/e2e.yml` workflow file
- [ ] CHK037 Configure E2E workflow to run on push to all branches
- [ ] CHK038 Configure matrix for individual E2E test jobs (dns, mdns, dhcpv4, dhcpv6)
- [ ] CHK039 Configure combined E2E test job (test.e2e)
- [ ] CHK040 Configure proper caching for dependencies
- [ ] CHK041 Configure non-privileged port usage for CI environment
- [ ] CHK042 Verify E2E workflow passes on feature branch
- [ ] CHK043 Verify E2E workflow passes on main branch after merge

## Documentation

- [ ] CHK044 Update CLAUDE.md with E2E test commands
- [ ] CHK045 Add E2E test section to project documentation

## Notes

- Check items off as completed: `[x]`
- Add comments or findings inline
- Link to relevant resources or documentation
- Items are numbered sequentially for easy reference
