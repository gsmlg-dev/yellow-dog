# Feature Specification: Service Diagnostics Page

**Feature Branch**: `001-service-diagnostics`
**Created**: 2025-12-19
**Status**: Draft
**Input**: User description: "Implement /diagnostics Route - Create a Phoenix LiveView page at /diagnostics with 4 tabs for testing network services (DNS, mDNS, DHCPv4, DHCPv6). Use ex_dns and ex_dhcp libraries for message encoding/decoding. Each tab has forms for sending queries and displays request/response with struct and raw hex views."

## Clarifications

### Session 2025-12-19

- Q: Where/how do users access query history relative to the form and results? → A: Collapsible history panel below the form (shows list of past queries)
- Q: Can users modify timeout values per-query? → A: User-configurable timeout field in each tab's form (with defaults shown)

## User Scenarios & Testing *(mandatory)*

### User Story 1 - DNS Query Testing (Priority: P1)

As a network administrator, I want to send DNS queries to test my DNS server configuration so that I can verify name resolution is working correctly.

**Why this priority**: DNS is the most commonly used and frequently tested network service. Administrators need to verify DNS resolution before troubleshooting other services.

**Independent Test**: Can be fully tested by entering a domain name and query type, clicking send, and viewing the DNS response. Delivers immediate diagnostic value for DNS troubleshooting.

**Acceptance Scenarios**:

1. **Given** I am on the DNS tab, **When** I enter "example.com" as query name, select "A" as record type, and click send, **Then** I see the DNS query and response displayed with latency in milliseconds
2. **Given** I have sent a DNS query, **When** I toggle between "Struct" and "Raw" views, **Then** I see the response formatted as a readable struct or as a hex dump respectively
3. **Given** I am on the DNS tab, **When** I configure a custom server address and port, **Then** the query is sent to that specific server
4. **Given** I have performed multiple queries, **When** I view the query history, **Then** I see up to 10 recent queries that I can review

---

### User Story 2 - mDNS Service Discovery Testing (Priority: P2)

As a network administrator, I want to send mDNS queries to discover local services so that I can verify mDNS responders are advertising services correctly on the network.

**Why this priority**: mDNS is essential for local service discovery and is the second most common diagnostic need after DNS.

**Independent Test**: Can be fully tested by entering a service type like "_http._tcp.local", setting a timeout, and viewing multicast responses. Delivers value for local network service troubleshooting.

**Acceptance Scenarios**:

1. **Given** I am on the mDNS tab, **When** I enter "_http._tcp.local" as service type and click send, **Then** I see responses from all mDNS responders collected until the timeout expires
2. **Given** I have sent an mDNS query, **When** multiple responses arrive, **Then** each response is displayed separately with its source address
3. **Given** I am on the mDNS tab, **When** I adjust the timeout value, **Then** the system waits that duration before stopping response collection

---

### User Story 3 - DHCPv4 Message Testing (Priority: P3)

As a network administrator, I want to send DHCPv4 messages to test my DHCP server so that I can verify IP address allocation is working correctly.

**Why this priority**: DHCP testing requires privileged ports and is less frequently needed than DNS/mDNS testing, but essential for network provisioning diagnostics.

**Independent Test**: Can be fully tested by configuring a DISCOVER message with a MAC address and viewing the server's OFFER response. Delivers value for DHCP server troubleshooting.

**Acceptance Scenarios**:

1. **Given** I am on the DHCPv4 tab, **When** I configure a DISCOVER message with a client MAC address and click send, **Then** I see the DHCP request and any OFFER response displayed
2. **Given** I am about to send a DHCPv4 message, **When** the page loads, **Then** I see a warning about privileged port requirements (port 67/68)
3. **Given** I have sent a DHCPv4 message, **When** I toggle to Raw view, **Then** I see the message as a hex dump with ASCII sidebar

---

### User Story 4 - DHCPv6 Message Testing (Priority: P4)

As a network administrator, I want to send DHCPv6 messages to test my DHCPv6 server so that I can verify IPv6 address allocation is working correctly.

**Why this priority**: DHCPv6 is similar to DHCPv4 but for IPv6 networks. It requires privileged ports and is needed for IPv6-enabled network diagnostics.

**Independent Test**: Can be fully tested by configuring a SOLICIT message with a DUID and viewing the server's ADVERTISE response. Delivers value for IPv6 DHCP troubleshooting.

**Acceptance Scenarios**:

1. **Given** I am on the DHCPv6 tab, **When** I configure a SOLICIT message with a DUID and click send, **Then** I see the DHCPv6 request and any ADVERTISE response displayed
2. **Given** I am about to send a DHCPv6 message, **When** the page loads, **Then** I see a warning about privileged port requirements (port 546/547)
3. **Given** I have sent a DHCPv6 message, **When** I copy the response to clipboard, **Then** the struct or raw view content is copied based on current view selection

---

### User Story 5 - Response Display and Copy (Priority: P2)

As a network administrator, I want to view responses in both structured and raw hex formats and copy them to clipboard so that I can analyze and share diagnostic results.

**Why this priority**: Essential for all diagnostic workflows - users need to understand and share results effectively.

**Independent Test**: Can be fully tested after any query by toggling views and using the copy button. Delivers value by enabling detailed analysis and collaboration.

**Acceptance Scenarios**:

1. **Given** I have received any protocol response, **When** I select "Struct" view, **Then** I see the response formatted as a readable data structure with field names and values
2. **Given** I have received any protocol response, **When** I select "Raw" view, **Then** I see a hex dump with offset, hex bytes, and ASCII representation (xxd-style)
3. **Given** I am viewing a response, **When** I click the copy button, **Then** the current view content is copied to my clipboard with a confirmation message

---

### Edge Cases

- What happens when the target server is unreachable? System displays a user-friendly error message with the socket error details and elapsed time before timeout.
- What happens when no response is received within timeout? System displays "No response received" with the timeout duration used.
- What happens when the response is malformed? System displays the raw bytes with an error message indicating parsing failed.
- What happens when DHCP messages are sent without root/admin privileges? System displays a clear error explaining that ports 67/68 (DHCPv4) or 546/547 (DHCPv6) require elevated privileges.
- What happens when query history exceeds 10 entries? The oldest entry is removed to maintain the 10-entry limit per tab.

## Requirements *(mandatory)*

### Functional Requirements

#### General Requirements
- **FR-001**: System MUST provide a diagnostics page accessible at the `/diagnostics` route
- **FR-002**: System MUST organize diagnostics into 4 tabs: DNS, mDNS, DHCPv4, and DHCPv6
- **FR-003**: System MUST display request latency in milliseconds for each query
- **FR-004**: System MUST handle socket errors gracefully with user-friendly error messages
- **FR-005**: System MUST perform network operations asynchronously without blocking the user interface
- **FR-006**: System MUST maintain a history of the last 10 queries per tab
- **FR-007**: System MUST display query history in a collapsible panel below the form, allowing users to view and re-select past queries

#### DNS Tab Requirements
- **FR-010**: System MUST provide a form with fields: query name, record type, server address, port, protocol (UDP/TCP), recursion desired flag, and timeout (default: 5 seconds)
- **FR-011**: System MUST support common DNS record types: A, AAAA, MX, TXT, CNAME, NS, SOA, PTR, SRV
- **FR-012**: System MUST default to querying the local DNS server (127.0.0.1:53)
- **FR-013**: System MUST support both UDP and TCP protocols for DNS queries

#### mDNS Tab Requirements
- **FR-020**: System MUST provide a form with fields: service type, query type, and timeout (default: 3 seconds)
- **FR-021**: System MUST send mDNS queries to the multicast address 224.0.0.251 on port 5353
- **FR-022**: System MUST collect and display multiple responses until the timeout expires
- **FR-023**: System MUST display the source address for each mDNS response received

#### DHCPv4 Tab Requirements
- **FR-030**: System MUST provide a form with fields: message type, client MAC address, transaction ID, requested options, and timeout (default: 10 seconds)
- **FR-031**: System MUST support DHCPv4 message types: DISCOVER, REQUEST, DECLINE, RELEASE, INFORM
- **FR-032**: System MUST send DHCPv4 messages to the broadcast address 255.255.255.255 on port 67
- **FR-033**: System MUST display a warning about privileged port requirements before sending

#### DHCPv6 Tab Requirements
- **FR-040**: System MUST provide a form with fields: message type, DUID, transaction ID, requested options, and timeout (default: 10 seconds)
- **FR-041**: System MUST support DHCPv6 message types: SOLICIT, REQUEST, RENEW, REBIND, RELEASE, DECLINE, INFORMATION-REQUEST
- **FR-042**: System MUST send DHCPv6 messages to the multicast address ff02::1:2 on port 547
- **FR-043**: System MUST display a warning about privileged port requirements before sending

#### Display Requirements
- **FR-050**: System MUST provide a toggle between "Struct" view (formatted data structure) and "Raw" view (hex dump)
- **FR-051**: System MUST display raw view in xxd-style format with offset, hex bytes, and ASCII sidebar
- **FR-052**: System MUST provide copy-to-clipboard functionality for both request and response content
- **FR-053**: System MUST display both the sent request and received response for each query

### Key Entities

- **Query**: Represents a diagnostic query with fields: protocol type, form parameters, timestamp, request bytes, response bytes, latency, status (success/error/timeout)
- **QueryHistory**: A per-tab collection of recent queries, limited to 10 entries, with newest first ordering
- **DisplayMode**: The current view mode for request/response display (struct or raw hex)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can send a DNS query and view the response in under 5 seconds for responsive servers
- **SC-002**: Users can discover local mDNS services within the configured timeout period
- **SC-003**: Users can copy diagnostic results to clipboard with a single click
- **SC-004**: Users can switch between tabs without losing query history for other tabs
- **SC-005**: Error messages clearly identify the cause of failure (timeout, connection refused, permission denied, etc.)
- **SC-006**: Query history persists within the browser session until page refresh or tab close
- **SC-007**: 95% of valid queries to responsive servers complete without user-perceived errors
- **SC-008**: Users can understand the warning messages about privileged ports and take appropriate action

## Assumptions

- The ex_dns and ex_dhcp libraries are already available in the project for message encoding/decoding
- The web console is running in an environment where UDP/TCP sockets can be opened (though DHCP may require elevated privileges)
- Users accessing this page have basic understanding of network protocols and diagnostic terminology
- Timeout values are user-configurable per-query with defaults: DNS 5 seconds, mDNS 3 seconds, DHCP 10 seconds
- Auto-generated values for optional fields: random transaction ID (xid), random MAC address for testing
- Query history is stored in LiveView assigns (session-scoped, not persistent across page reloads)
