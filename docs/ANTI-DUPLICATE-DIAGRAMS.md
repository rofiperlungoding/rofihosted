# Anti-duplicate account system: flow diagrams

## Complete signup flow

```mermaid
flowchart TD
    Start[User submits signup form] --> CollectFP[Collect device fingerprint]
    CollectFP --> ValidateInput[Validate input fields]
    ValidateInput --> CheckIPLimit{Check IP rate limit<br/>Max 3 per 24h}
    
    CheckIPLimit -->|Exceeded| BlockIP[Block: Too many attempts]
    CheckIPLimit -->|OK| CheckDevice{Check device fingerprint<br/>Max 2 signups}
    
    CheckDevice -->|Exceeded| BlockDevice[Block: Device limit reached]
    CheckDevice -->|OK| CheckUnique{Username and email<br/>unique?}
    
    CheckUnique -->|Duplicate| RejectDup[Reject: Already exists]
    CheckUnique -->|Unique| CheckInvite{Has invite code?}
    
    CheckInvite -->|Yes| ValidateInvite{Invite valid?}
    ValidateInvite -->|No| RejectInvite[Reject: Invalid invite]
    ValidateInvite -->|Yes| CreateUserActive[Create user<br/>Status: Active]
    
    CheckInvite -->|No| CreateUserPending[Create user<br/>Status: Pending verification]
    
    CreateUserPending --> GenToken[Generate 6-digit code]
    GenToken --> SendEmail[Send verification email]
    SendEmail --> StoreData[Store IP and fingerprint]
    StoreData --> RedirectVerify[Redirect to verification page]
    
    CreateUserActive --> StoreDataActive[Store IP and fingerprint]
    StoreDataActive --> IssueCookie[Issue session cookie]
    IssueCookie --> RedirectDash[Redirect to dashboard]
    
    RedirectVerify --> UserInputCode[User inputs code]
    UserInputCode --> VerifyCode{Code valid?}
    
    VerifyCode -->|No| CheckAttempts{Attempts less than 3?}
    CheckAttempts -->|Yes| ShowError[Show error]
    ShowError --> UserInputCode
    CheckAttempts -->|No| BlockVerify[Block: Max attempts]
    
    VerifyCode -->|Yes| ActivateUser[Activate user account]
    ActivateUser --> IssueCookie
    
    BlockIP --> End[End]
    BlockDevice --> End
    RejectDup --> End
    RejectInvite --> End
    BlockVerify --> End
    RedirectDash --> End
```

## Email verification flow

```mermaid
sequenceDiagram
    participant U as User
    participant F as Frontend
    participant B as Backend
    participant E as Email service
    participant D as Database
    
    U->>F: Submit signup form
    F->>B: POST /signup/submit
    B->>B: Validate input
    B->>B: Check rate limits
    B->>D: Create user (pending_verification)
    B->>B: Generate 6-digit code
    B->>E: Send verification email
    E-->>U: Email with code
    B->>F: Return success with verification_required
    F->>U: Show verification page
    
    U->>F: Input verification code
    F->>B: POST /signup/verify-email
    B->>B: Validate code
    B->>D: Update user (active)
    B->>F: Return success
    F->>U: Redirect to dashboard
```

## Device fingerprinting process

```mermaid
flowchart LR
    subgraph Browser
        A[Collect browser data] --> B[User agent]
        A --> C[Screen resolution]
        A --> D[Timezone]
        A --> E[Canvas fingerprint]
        A --> F[WebGL fingerprint]
        A --> G[Audio context]
        A --> H[Hardware info]
    end
    
    B --> I[Combine all data]
    C --> I
    D --> I
    E --> I
    F --> I
    G --> I
    H --> I
    
    I --> J[SHA256 hash]
    J --> K[Send to backend]
    
    subgraph Backend
        K --> L{Fingerprint exists?}
        L -->|Yes| M{Signup count less than 2?}
        L -->|No| N[Store new fingerprint]
        M -->|Yes| O[Increment count]
        M -->|No| P[Block signup]
        O --> Q[Allow signup]
        N --> Q
    end
```

## Rate limiting architecture

```mermaid
flowchart TD
    subgraph Rate limiter
        A[Incoming signup request] --> B[Extract IP address]
        B --> C{IP in cache?}
        
        C -->|No| D[Create new entry<br/>Count: 1<br/>Window: 24h]
        C -->|Yes| E{Within window?}
        
        E -->|No| F[Reset entry<br/>Count: 1<br/>New window]
        E -->|Yes| G{Count less than max?}
        
        G -->|Yes| H[Increment count]
        G -->|No| I[Block request]
        
        D --> J[Allow request]
        F --> J
        H --> J
    end
    
    J --> K[Continue signup flow]
    I --> L[Return error]
```

## Data storage structure

```mermaid
erDiagram
    USER ||--o{ FINGERPRINT : has
    USER ||--o{ VERIFICATION_TOKEN : has
    USER ||--o{ SIGNUP_ATTEMPT : has
    
    USER {
        string id PK
        string username
        string email
        bool email_verified
        timestamp email_verified_at
        string device_fingerprint FK
        string signup_ip
        int verification_attempts
    }
    
    FINGERPRINT {
        string hash PK
        string user_agent
        string screen_resolution
        string timezone
        string canvas_hash
        timestamp first_seen
        timestamp last_seen
        int signup_count
    }
    
    VERIFICATION_TOKEN {
        string email PK
        string code
        string username
        timestamp created_at
        timestamp expires_at
        int attempts
    }
    
    SIGNUP_ATTEMPT {
        string ip PK
        int count
        timestamp first_attempt
        timestamp last_attempt
        string usernames
    }
```

## Component architecture

```mermaid
graph TB
    subgraph Frontend
        A[signup.html] --> B[Fingerprint collector]
        A --> C[Verification page]
    end
    
    subgraph Backend
        D[main.zig] --> E[emailverify.zig]
        D --> F[fingerprint.zig]
        D --> G[ratelimit.zig]
        D --> H[users.zig]
        
        E --> I[SMTP client]
        F --> J[Fingerprint storage]
        G --> K[Rate limit cache]
        H --> L[User database]
    end
    
    B --> D
    C --> D
    
    I --> M[Email service]
    J --> N[.hp-server-fingerprints.jsonl]
    L --> O[.hp-server-users.jsonl]
```

## Security layers

```mermaid
flowchart TD
    A[Signup request] --> B[Layer 1: Input validation]
    B --> C[Layer 2: IP rate limiting]
    C --> D[Layer 3: Device fingerprinting]
    D --> E[Layer 4: Email verification]
    E --> F[Layer 5: Username and email uniqueness]
    F --> G[Layer 6: Invite code validation]
    G --> H[Layer 7: Admin approval]
    H --> I[Account created]
    
    B -.->|Invalid| Z[Reject]
    C -.->|Exceeded| Z
    D -.->|Duplicate| Z
    E -.->|Failed| Z
    F -.->|Taken| Z
    G -.->|Invalid| Z
    H -.->|Rejected| Z
```

## Monitoring dashboard (future)

```mermaid
flowchart LR
    subgraph Metrics
        A[Total signups] --> D[Dashboard]
        B[Blocked attempts] --> D
        C[Verification rate] --> D
    end
    
    subgraph Breakdown
        D --> E[By IP]
        D --> F[By device]
        D --> G[By reason]
    end
    
    subgraph Actions
        E --> H[Whitelist IP]
        F --> I[Reset device]
        G --> J[Adjust limits]
    end
```

---

**Legend**:
- Solid lines = Success path
- Dashed lines = Blocked or rejected
- PK = Primary key
- FK = Foreign key