# YellowDog DNS Recursive Resolver - Architecture Diagrams

This document provides visual representations of the recursive resolver architecture.

---

## 1. Complete System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          YellowDog DNS Server                        │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Abyss UDP Server                            │ │
│  │                    (Port 53)                                   │ │
│  └───────────────────────────┬────────────────────────────────────┘ │
│                              │                                       │
│  ┌───────────────────────────▼────────────────────────────────────┐ │
│  │              YellowDog.Dns.Handler.UDP                         │ │
│  │              (DNS Message Handler)                             │ │
│  └───────┬────────────────────────────────────────┬───────────────┘ │
│          │                                        │                  │
│          ▼                                        ▼                  │
│  ┌──────────────────┐                   ┌──────────────────┐        │
│  │  View Manager    │                   │  Cache Lookup    │        │
│  │  (Client IP      │                   │  (Resolver       │        │
│  │   Matching)      │                   │   Cache)         │        │
│  └──────┬───────────┘                   └──────┬───────────┘        │
│         │                                      │                    │
│         ▼                                      ▼                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │           YellowDog.Dns.Query.Resolver                      │   │
│  │           (Resolution Coordinator)                          │   │
│  └───┬─────────────────┬──────────────────┬───────────────────┘   │
│      │                 │                  │                        │
│      ▼                 ▼                  ▼                        │
│  ┌────────┐    ┌──────────────┐   ┌──────────────────────┐       │
│  │ Author │    │   Forward    │   │    Recursive         │       │
│  │ -itat  │    │    Zones     │   │    Resolver          │       │
│  │  ive   │    │              │   │   (NEW)              │       │
│  │ Zones  │    │              │   │                      │       │
│  └────────┘    └──────────────┘   └──────────┬───────────┘       │
│                                               │                    │
│                                               ▼                    │
│                            ┌──────────────────────────────────┐   │
│                            │  Recursive Resolution System     │   │
│                            │  (See Detail Below)              │   │
│                            └──────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 2. Recursive Resolution System (Detailed)

```
┌───────────────────────────────────────────────────────────────────────┐
│                  Recursive Resolution System                          │
│                                                                       │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │          YellowDog.Dns.Query.Recursive                         │  │
│  │          (Main Recursive Resolver)                             │  │
│  │                                                                │  │
│  │  • Query coordination                                          │  │
│  │  • State management                                            │  │
│  │  • CNAME chain following                                       │  │
│  │  • Loop detection                                              │  │
│  │  • Depth limiting                                              │  │
│  │  • Timeout enforcement                                         │  │
│  └────────┬───────────────────────────────────────────┬───────────┘  │
│           │                                           │              │
│           ▼                                           ▼              │
│  ┌─────────────────────┐                   ┌──────────────────────┐ │
│  │  Root Zone Manager  │                   │  Resolver Cache      │ │
│  │                     │                   │                      │ │
│  │  ┌──────────────┐   │                   │  • ETS storage       │ │
│  │  │   Strategy   │   │                   │  • TTL tracking      │ │
│  │  │   Selector   │   │                   │  • Auto cleanup      │ │
│  │  └──────┬───────┘   │                   │  • Statistics        │ │
│  │         │           │                   └──────────────────────┘ │
│  │    ┌────┼────┐      │                                            │
│  │    ▼    ▼    ▼      │                                            │
│  │  ┌────┐┌────┐┌────┐ │                                            │
│  │  │Hint││Ftch││Auth│ │                                            │
│  │  │s   ││er  ││    │ │                                            │
│  │  └────┘└────┘└────┘ │                                            │
│  └─────────────────────┘                                            │
│           │                                                          │
│           ▼ (root servers)                                          │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │          YellowDog.Dns.Query.Iterator                        │  │
│  │          (Single Iteration Logic)                            │  │
│  │                                                              │  │
│  │  • Parallel nameserver queries                               │  │
│  │  • Response parsing (answer/referral)                        │  │
│  │  • Glue record extraction                                    │  │
│  │  • Referral validation                                       │  │
│  └──────────────────────┬───────────────────────────────────────┘  │
│                         │                                           │
│                         ▼ (query)                                   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                  Nameservers                                 │   │
│  │  (Root → TLD → Authoritative)                                │   │
│  │                                                              │   │
│  │  • Task.async_stream for parallelism                         │   │
│  │  • First successful wins                                     │   │
│  │  • UDP queries with timeout                                  │   │
│  └─────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────┘
```

---

## 3. Root Zone Management Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│              YellowDog.Dns.RootZone.Manager                       │
│              (GenServer)                                          │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Strategy Configuration                                     │ │
│  │  (TOML: strategy = "hints" | "fetch" | "auth")             │ │
│  └───────────────────────┬─────────────────────────────────────┘ │
│                          │                                        │
│         ┌────────────────┼────────────────┐                      │
│         │                │                │                      │
│         ▼                ▼                ▼                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   HINTS     │  │   FETCH     │  │    AUTH     │             │
│  │  Strategy   │  │  Strategy   │  │  Strategy   │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
└───────┬─────────────────┬─────────────────┬───────────────────────┘
        │                 │                 │
        ▼                 ▼                 ▼

┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Embedded Data   │  │  HTTP Fetcher    │  │  Zone File       │
│                  │  │  (GenServer)     │  │  Loader          │
│  • 13 root       │  │                  │  │                  │
│    servers       │  │  • Downloads     │  │  • Reads local   │
│  • IPv4 + IPv6   │  │    root.zone     │  │    zone file     │
│  • Hardcoded     │  │  • Periodic      │  │  • BIND format   │
│  • Fast          │  │    updates       │  │  • Manual        │
│  • Reliable      │  │  • Falls back    │  │    management    │
│                  │  │    to hints      │  │  • Custom TLDs   │
└──────────────────┘  └──────────────────┘  └──────────────────┘
        │                     │                     │
        │                     ▼                     ▼
        │           ┌──────────────────┐  ┌──────────────────┐
        │           │  Zone.Parser     │  │  Zone.Parser     │
        │           │  (BIND format)   │  │  (BIND format)   │
        │           └────────┬─────────┘  └────────┬─────────┘
        │                    │                     │
        │                    ▼                     ▼
        │           ┌─────────────────────────────────────┐
        └──────────►│      Zone.Storage (ETS)             │
                    │      (zone = ".")                   │
                    │                                     │
                    │  • NS records for root              │
                    │  • Glue records (A/AAAA)            │
                    └─────────────────────────────────────┘
```

---

## 4. Iterative Resolution Flow

```
START
  │
  ▼
┌─────────────────────────────────┐
│ Get Root Nameservers            │
│ (RootZone.Manager)              │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Initialize State                │
│ • depth = 0                     │
│ • servers = roots               │
│ • referral_chain = []           │
│ • query_name = "www.example.com"│
│ • query_type = A                │
└────────────┬────────────────────┘
             │
             ▼
       ┌─────────────┐
       │ ITERATION   │◄──────────────┐
       │   LOOP      │               │
       └─────┬───────┘               │
             │                       │
             ▼                       │
┌─────────────────────────────────┐  │
│ Query Nameservers               │  │
│ (Iterator.query_nameservers)    │  │
│                                 │  │
│ Parallel queries:               │  │
│ • Task.async_stream             │  │
│ • First success wins            │  │
│ • Timeout per server            │  │
└────────────┬────────────────────┘  │
             │                       │
      ┌──────┴──────┐               │
      │ Parse       │               │
      │ Response    │               │
      └──────┬──────┘               │
             │                       │
    ┌────────┼────────┐             │
    │        │        │             │
    ▼        ▼        ▼             │
┌─────┐ ┌────────┐ ┌──────┐        │
│ANSWR│ │REFERRAL│ │NXDMN │        │
└──┬──┘ └───┬────┘ └───┬──┘        │
   │        │          │            │
   │        ▼          │            │
   │  ┌──────────────┐ │            │
   │  │ Extract NS & │ │            │
   │  │ Glue Records │ │            │
   │  └───────┬──────┘ │            │
   │          │        │            │
   │          ▼        │            │
   │  ┌──────────────┐ │            │
   │  │ Validate     │ │            │
   │  │ Referral     │ │            │
   │  └───────┬──────┘ │            │
   │          │        │            │
   │          ▼        │            │
   │  ┌──────────────┐ │            │
   │  │ Check Loop   │ │            │
   │  └───────┬──────┘ │            │
   │          │        │            │
   │          ▼        │            │
   │  ┌──────────────┐ │            │
   │  │ depth++      │ │            │
   │  │ Update state │ │            │
   │  └───────┬──────┘ │            │
   │          │        │            │
   │          ▼        │            │
   │  ┌──────────────┐ │            │
   │  │ depth < max? │─┼────────────┘
   │  └──────────────┘ │
   │                   │
   ▼                   ▼
┌──────────┐      ┌──────────┐
│ Cache &  │      │ Return   │
│ Return   │      │ Error    │
│ Answer   │      │          │
└──────────┘      └──────────┘
```

---

## 5. Cache Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│          YellowDog.Dns.Cache.ResolverCache (GenServer)            │
└───────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────────┐
│                    ETS Table: :dns_recursive_cache                │
│                                                                   │
│  Key: {normalized_name, query_type}                               │
│  Value: Cache.Entry struct                                        │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Cache.Entry                                                │ │
│  │  • query_name: "www.example.com"                            │ │
│  │  • query_type: :A                                           │ │
│  │  • records: [%Record{...}]                                  │ │
│  │  • ttl: 300                                                 │ │
│  │  • cached_at: 1730209843                                    │ │
│  │  • expires_at: 1730210143                                   │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Options:                                                         │
│  • :set - One entry per key                                       │
│  • :public - Accessible from all processes                        │
│  • :named_table - Named for easy access                           │
│  • read_concurrency: true - Fast lookups                          │
│  • write_concurrency: true - Fast inserts                         │
└───────────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────┐
                    │  Periodic Cleanup     │
                    │  (every 5 minutes)    │
                    │                       │
                    │  • Delete expired     │
                    │  • Update stats       │
                    └───────────────────────┘

Cache Types:
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  Answer Cache    │  │   NS Cache       │  │ Negative Cache   │
│                  │  │                  │  │                  │
│  • Final answers │  │  • NS records    │  │  • NXDOMAIN      │
│  • Full TTL      │  │  • Glue records  │  │  • Shorter TTL   │
│  • High priority │  │  • Intermediate  │  │  • Error caching │
└──────────────────┘  └──────────────────┘  └──────────────────┘
```

---

## 6. Data Flow Diagram

```
Client Query
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│ Handler.UDP: Receive UDP packet                             │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Parse DNS Message (DNS.Message.from_iodata)                 │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Match View by Client IP                                     │
│ • Check if recursion allowed                                │
└────────────────────────────┬────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│ Check Resolver Cache                                        │
│ • Key: {query_name, query_type}                             │
└────────┬───────────────────────────────┬────────────────────┘
         │ HIT                           │ MISS
         ▼                               ▼
    ┌────────┐           ┌──────────────────────────────────┐
    │ Return │           │ Query.Resolver.resolve()         │
    │ Cached │           └───────────┬──────────────────────┘
    └────────┘                       │
                                     ▼
                     ┌───────────────────────────────┐
                     │ Check Authoritative Zones     │
                     └───────┬───────────────┬───────┘
                             │ FOUND         │ NOT FOUND
                             ▼               ▼
                        ┌────────┐    ┌─────────────┐
                        │Return  │    │Check Forward│
                        │Auth    │    │   Zones     │
                        └────────┘    └──────┬──────┘
                                             │
                                    ┌────────┴────────┐
                                    │ FOUND  │NOT FOUND│
                                    ▼        ▼
                              ┌────────┐ ┌──────────┐
                              │Forward │ │Recursive?│
                              │Answer  │ └─────┬────┘
                              └────────┘       │ YES
                                               ▼
                    ┌──────────────────────────────────────────┐
                    │ Query.Recursive.resolve()                │
                    └───────────┬──────────────────────────────┘
                                │
                                ▼
                    ┌───────────────────────────────┐
                    │ Get Root Servers              │
                    │ (RootZone.Manager)            │
                    └───────────┬───────────────────┘
                                │
                                ▼
                    ┌───────────────────────────────┐
                    │ Iterative Resolution Loop     │
                    │ (Iterator.query_nameservers)  │
                    │                               │
                    │  1. Root → TLD referral       │
                    │  2. TLD → Auth referral       │
                    │  3. Auth → Answer             │
                    └───────────┬───────────────────┘
                                │
                                ▼
                    ┌───────────────────────────────┐
                    │ Cache Result                  │
                    │ (ResolverCache.insert)        │
                    └───────────┬───────────────────┘
                                │
                                ▼
┌───────────────────────────────────────────────────────────────┐
│ Build DNS Response Message                                    │
│ • Copy query ID                                               │
│ • Set QR=1, AA bit                                            │
│ • Add answer records                                          │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────┐
│ Serialize to Binary (DNS.Parameter.to_iodata)                 │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────────────┐
│ Send UDP Response to Client                                   │
└───────────────────────────────────────────────────────────────┘
                            │
                            ▼
                     Emit Telemetry
```

---

## 7. Module Dependency Graph

```
                    YellowDog.Dns.Supervisor
                             │
                             │ supervises
                             │
            ┌────────────────┼────────────────┐
            │                │                │
            ▼                ▼                ▼
    ┌──────────────┐  ┌───────────┐  ┌─────────────┐
    │ Zone.Manager │  │   Server  │  │ RootZone.   │
    │              │  │           │  │  Manager    │
    └──────────────┘  └─────┬─────┘  └──────┬──────┘
                            │               │
                            │               │ uses
                            │               │
                            ▼               ▼
                    ┌────────────────────────────┐
                    │   Handler.UDP              │
                    └────────┬───────────────────┘
                             │
                             │ uses
                             │
                             ▼
                    ┌────────────────────┐
                    │  Query.Resolver    │
                    └────────┬───────────┘
                             │
                             │ uses
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐  ┌──────────────────┐  ┌──────────────┐
│Query.Forwarder│  │Query.Recursive   │  │Zone.Storage  │
│               │  │                  │  │              │
└───────────────┘  └────┬─────────────┘  └──────────────┘
                        │
                        │ uses
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
┌──────────────┐ ┌─────────────┐ ┌────────────────┐
│RootZone.     │ │Query.       │ │Cache.Resolver  │
│ Manager      │ │ Iterator    │ │  Cache         │
└──────────────┘ └─────────────┘ └────────────────┘
```

---

## 8. Glue Record Handling

```
Scenario: Resolving www.example.com

Step 1: Query Root Servers
┌────────────────────────────────────────────┐
│ Query: www.example.com A                   │
│ To: 198.41.0.4 (a.root-servers.net)        │
└────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────┐
│ Response:                                  │
│                                            │
│ AUTHORITY SECTION:                         │
│   com. NS a.gtld-servers.net.              │
│   com. NS b.gtld-servers.net.              │
│                                            │
│ ADDITIONAL SECTION (GLUE):                 │
│   a.gtld-servers.net. A 192.5.6.30         │
│   b.gtld-servers.net. A 192.33.14.30       │
└────────────────────────────────────────────┘
                    │
                    │ extract glue
                    ▼
┌────────────────────────────────────────────┐
│ Iterator.extract_glue_records()            │
│                                            │
│ Input:                                     │
│   ns_records: [a.gtld-servers.net,         │
│                b.gtld-servers.net]         │
│   ar_records: [A records for both]         │
│                                            │
│ Output:                                    │
│   [{name: "a.gtld-servers.net",            │
│     address: {192,5,6,30}},                │
│    {name: "b.gtld-servers.net",            │
│     address: {192,33,14,30}}]              │
└────────────────────────────────────────────┘
                    │
                    ▼
Step 2: Query .com Nameservers
┌────────────────────────────────────────────┐
│ Query: www.example.com A                   │
│ To: 192.5.6.30 (a.gtld-servers.net)        │
└────────────────────────────────────────────┘
                    │
                    ▼
┌────────────────────────────────────────────┐
│ Response:                                  │
│                                            │
│ AUTHORITY SECTION:                         │
│   example.com. NS ns1.example.com.         │
│   example.com. NS ns2.example.com.         │
│                                            │
│ ADDITIONAL SECTION (GLUE):                 │
│   ns1.example.com. A 192.0.2.1             │
│   ns2.example.com. A 192.0.2.2             │
└────────────────────────────────────────────┘
                    │
                    │ glue present
                    ▼
Continue to Step 3 with glue addresses


Missing Glue Scenario:
┌────────────────────────────────────────────┐
│ Response:                                  │
│                                            │
│ AUTHORITY SECTION:                         │
│   example.com. NS ns1.example.com.         │
│   example.com. NS ns2.example.com.         │
│                                            │
│ ADDITIONAL SECTION:                        │
│   (empty - NO GLUE!)                       │
└────────────────────────────────────────────┘
                    │
                    │ no glue!
                    ▼
┌────────────────────────────────────────────┐
│ Recursive.resolve_nameserver_addresses()   │
│                                            │
│ Perform "sidequery":                       │
│   1. Resolve ns1.example.com A             │
│   2. Resolve ns2.example.com A             │
│   3. Use resolved addresses                │
│                                            │
│ Limit: remaining depth budget              │
└────────────────────────────────────────────┘
                    │
                    ▼
Continue resolution with resolved NS addresses
```

---

## 9. Error Handling Flow

```
                    Query Start
                         │
                         ▼
            ┌────────────────────────┐
            │  Check Depth Limit     │
            │  (depth < max_depth?)  │
            └────────┬───────────────┘
                     │ NO
                     ▼
            ┌────────────────────────┐
            │  ERROR:                │
            │  max_depth_exceeded    │
            │  → SERVFAIL            │
            └────────────────────────┘

                     │ YES
                     ▼
            ┌────────────────────────┐
            │  Check Timeout         │
            │  (elapsed < timeout?)  │
            └────────┬───────────────┘
                     │ NO
                     ▼
            ┌────────────────────────┐
            │  ERROR:                │
            │  timeout               │
            │  → SERVFAIL            │
            └────────────────────────┘

                     │ YES
                     ▼
            ┌────────────────────────┐
            │  Query Nameservers     │
            └────────┬───────────────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
        ▼            ▼            ▼
   ┌────────┐  ┌─────────┐  ┌──────────┐
   │All NS  │  │Referral │  │ Answer   │
   │Failed  │  │  Loop   │  │ Success  │
   └───┬────┘  └────┬────┘  └────┬─────┘
       │            │            │
       ▼            ▼            │
   ┌────────┐  ┌─────────┐      │
   │ERROR:  │  │ERROR:   │      │
   │all_ns  │  │referral │      │
   │_failed │  │_loop    │      │
   │→SERVFAL│  │→SERVFAL │      │
   └────────┘  └─────────┘      │
                                │
                                ▼
                        ┌──────────────┐
                        │ Cache Result │
                        │ Return Answer│
                        └──────────────┘

Telemetry Events on Errors:
┌────────────────────────────────────────┐
│ :yellow_dog, :dns, :recursive_error    │
│                                        │
│ Metadata:                              │
│   error: :max_depth_exceeded           │
│         :timeout                       │
│         :referral_loop                 │
│         :all_nameservers_failed        │
│         {:rcode, "SERVFAIL"}           │
│   query_name: "www.example.com"        │
│   depth: 16                            │
└────────────────────────────────────────┘
```

---

## 10. Performance Optimization Points

```
┌───────────────────────────────────────────────────────────────┐
│                    Performance Optimizations                  │
└───────────────────────────────────────────────────────────────┘

1. Caching Strategy
┌─────────────────────────────────────────┐
│ Multi-Level Cache                       │
│                                         │
│  ┌────────────────────────────────┐    │
│  │ Answer Cache (Final Results)   │    │
│  │ • High priority                 │    │
│  │ • Full TTL                      │    │
│  └────────────────────────────────┘    │
│                                         │
│  ┌────────────────────────────────┐    │
│  │ NS Cache (Referrals + Glue)    │    │
│  │ • Intermediate results          │    │
│  │ • Avoid repeated queries        │    │
│  └────────────────────────────────┘    │
│                                         │
│  ┌────────────────────────────────┐    │
│  │ Negative Cache (NXDOMAIN)      │    │
│  │ • Shorter TTL                   │    │
│  │ • Error caching                 │    │
│  └────────────────────────────────┘    │
└─────────────────────────────────────────┘

2. Parallel Queries
┌─────────────────────────────────────────┐
│ Task.async_stream                       │
│                                         │
│  NS Servers: [ns1, ns2, ns3, ns4]      │
│       │       │     │     │     │       │
│       └───────┴─────┴─────┴─────┘       │
│              Parallel Queries            │
│       ┌───────┬─────┬─────┬─────┐       │
│       ▼       ▼     ▼     ▼     ▼       │
│    Query   Query Query Query Query      │
│                                         │
│  First Successful Response Wins         │
│       (others are cancelled)            │
│                                         │
│  Benefits:                              │
│  • Reduced latency (fastest wins)       │
│  • Fault tolerance (retry others)       │
│  • Better resource utilization          │
└─────────────────────────────────────────┘

3. Connection Pooling (Future)
┌─────────────────────────────────────────┐
│ Socket Pool (10 sockets)                │
│                                         │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐   │
│  │Sock│ │Sock│ │Sock│ │Sock│ │Sock│   │
│  └────┘ └────┘ └────┘ └────┘ └────┘   │
│                                         │
│  Checkout → Use → Checkin               │
│                                         │
│  Benefits:                              │
│  • Reuse sockets                        │
│  • Reduce socket creation overhead      │
│  • Better resource management           │
└─────────────────────────────────────────┘

4. ETS Cache Configuration
┌─────────────────────────────────────────┐
│ :ets.new(:dns_recursive_cache, [        │
│   :set,                                 │
│   :public,                              │
│   :named_table,                         │
│   read_concurrency: true,   ← Fast reads│
│   write_concurrency: true   ← Fast writes│
│ ])                                      │
│                                         │
│  Read Concurrency:                      │
│  • Multiple processes can read          │
│  • No lock contention                   │
│                                         │
│  Write Concurrency:                     │
│  • Multiple processes can write         │
│  • Lock-free when possible              │
└─────────────────────────────────────────┘

5. Prefetching (Future)
┌─────────────────────────────────────────┐
│ Proactive Cache Refresh                 │
│                                         │
│  Entry: expires_at = T + 300            │
│                                         │
│  Access at T + 250:                     │
│  • Return cached entry                  │
│  • Trigger background refresh           │
│                                         │
│  Benefits:                              │
│  • Cache never expires for hot entries  │
│  • No cache miss delays                 │
│  • Smooth performance                   │
└─────────────────────────────────────────┘

Performance Targets:
┌─────────────────────────────────────────┐
│ • Latency: < 100ms (cached)             │
│ • Latency: < 500ms (recursive)          │
│ • Throughput: 1000+ queries/sec         │
│ • Cache Hit Rate: > 50%                 │
│ • Memory: < 100MB (10K entries)         │
└─────────────────────────────────────────┘
```

---

**END OF ARCHITECTURE DIAGRAMS**
