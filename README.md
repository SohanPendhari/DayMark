# DAYMARK

### Plan your day. Track your progress. Build better habits.

DayMark is a private, local-first task and productivity app designed to help you organize your day, manage reminders, stay focused, and understand your progress — without making your personal productivity data dependent on the cloud.

Built with **Flutter**, **Go**, and **PostgreSQL**, DayMark aims to combine a clean user experience with reliable offline functionality and secure device synchronization.

\<p align="center">
&#x20; \<strong>Private by design. Focused on progress. Built for everyday life.\</strong>
\</p>

---

## ✨ What is DayMark?

DayMark is being developed as a personal productivity workspace where you can manage tasks, organize projects, track progress, and build a more consistent daily routine.

The project follows a **local-first approach**: your device is the primary workspace, while the backend provides synchronization between paired devices.

### 🚀 Key Features

- **Task Management** — Organize daily tasks and keep track of what needs to get done.
- **Projects & Organization** — Group related tasks into a structured workflow.
- **Reminders & Notifications** — Stay aware of upcoming tasks and important activities.
- **Focus Timer** — Create dedicated time for focused work.
- **Progress Tracking** — Review your activity and understand how your days are going.
- **Offline-First Foundation** — Keep local data available even when a network connection is unavailable.
- **Device Synchronization** — Synchronize data between paired devices through the backend.
- **Conflict Resolution** — Detect conflicting edits and preserve values for manual resolution.
- **Backup & Restore** — Support controlled data recovery with validation and merge/replace options.
- **Privacy-Focused Design** — Use device pairing and revocable device credentials instead of a traditional account and password system.

> Some features are still under development. See the project status below for what is implemented and what remains.

---

## 🛠️ Tech Stack

| Layer              | Technology     |
| ------------------ | -------------- |
| Mobile & Web       | Flutter, Dart  |
| Backend API        | Go (Golang)    |
| Database           | PostgreSQL     |
| Local Storage      | Drift / SQLite |
| API Communication  | REST API       |
| Backend Deployment | Docker, Render |
| Version Control    | Git & GitHub   |

---

## 📂 Project Structure

```text
DayMark/
├── apps/
│   └── client/              # Flutter client foundation
│
├── backend/
│   ├── cmd/
│   │   └── api/             # API entry point
│   ├── internal/
│   │   ├── api/             # HTTP API handlers
│   │   ├── auth/            # Device authentication
│   │   ├── backup/          # Backup and restore
│   │   ├── config/          # Application configuration
│   │   ├── database/        # Database access
│   │   ├── security/        # Security utilities
│   │   └── sync/            # Synchronization logic
│   └── migrations/          # Database migrations
│
├── branding/
│   ├── source/              # Original brand artwork
│   ├── fonts/               # Brand fonts
│   ├── apply_brand.py        # Brand asset application
│   └── brand-guide.md       # Brand guidelines
│
├── docs/
│   ├── api-and-sync.md      # API and synchronization protocol
│   ├── security.md          # Security documentation
│   └── deployment.md        # Setup and deployment guide
│
├── .env.example
├── docker-compose.yml
├── render.yaml
└── README.md
```

*The structure above describes the intended layout; some client features are not implemented yet.*

---

## ⚡ Getting Started

### Prerequisites

Install the following tools before running the backend:

- [Git](https://git-scm.com/)
- [Go](https://go.dev/dl/)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Flutter SDK](https://docs.flutter.dev/get-started/install) — when working on the client

### 1. Clone the repository

```bash
git clone https://github.com/SohanPendhari/DayMark.git
cd DayMark
```

### 2. Configure environment variables

Create your local environment file:

**Windows PowerShell**

```powershell
Copy-Item .env.example .env
```

Open `.env` and configure the required values, including a strong PostgreSQL password and the setup secret.

Never commit your real `.env` file, database credentials, API keys, or other secrets.

### 3. Start the backend

From the project root, run:

```bash
docker compose up --build
```

To stop the services:

```bash
docker compose down
```

For detailed configuration, database setup, tests, deployment, and troubleshooting, see [Deployment Guide](docs/deployment.md).

> Make sure the Docker Compose filename and required environment variables match the files in the current repository before running these commands.

---

## 🔐 Privacy & Architecture

DayMark is designed around a few important principles.

- **Device-based authentication:** Pairing codes issue revocable credentials for individual devices.
- **No traditional user accounts:** The current design avoids a conventional email/password account system.
- **Revision-based synchronization:** Server revisions are used to detect conflicting changes rather than relying on device clocks.
- **Safe deletion handling:** Tombstones prevent stale devices from silently recreating deleted records.
- **Controlled recovery:** Backup restoration validates incoming data and provides explicit merge and replace behavior.

Learn more in the [Security Guide](docs/security.md) and [API & Sync Specification](docs/api-and-sync.md).

---

## 📊 Development Status

DayMark is an active development project. The backend foundation is ahead of the Flutter application.

| Component                                 | Status                                                 |
| ----------------------------------------- | ------------------------------------------------------ |
| Brand assets and theme foundation         | Implemented; Dart compilation still needs verification |
| Go backend and synchronization foundation | Implemented; automated tests reported passing          |
| Database migrations and backup/restore    | Implemented; verify in your environment                |
| Docker image and Render deployment        | Not yet verified                                       |
| Flutter application                       | Under development                                      |
| Full end-to-end application testing       | Pending                                                |

**Current priority:** Build out the Flutter application, connect it to the backend, and test the complete workflow on real devices.

---

## 🗺️ Roadmap

- [x] Establish the project structure and brand foundation
- [x] Implement the initial Go backend and synchronization protocol
- [x] Add device pairing and authentication
- [x] Implement conflict handling and backup/restore foundations
- [ ] Complete the Flutter application
- [ ] Integrate local storage with the synchronization engine
- [ ] Complete tasks, projects, reminders, and focus workflows
- [ ] Add progress reports and analytics
- [ ] Verify mobile and web behavior
- [ ] Complete end-to-end, security, and deployment testing

*Roadmap items reflect the intended direction and should be updated as development progresses.*

---

## 📚 Documentation

- [API & Synchronization Protocol](docs/api-and-sync.md)
- [Security Guide](docs/security.md)
- [Deployment Guide](docs/deployment.md)
- [Brand Guidelines](branding/brand-guide.md)

---

## 🤝 Contributing

DayMark is currently under active development.

If you want to contribute:

1. Fork the repository.
2. Create a feature branch.
3. Make your changes and test them.
4. Open a pull request describing your changes.

Please avoid including credentials, personal data, or production secrets in commits.

---

## 📄 License

The project's license has not yet been specified. Until a license is added, please do not assume that the source code is available for unrestricted reuse or redistribution.

---

\<p align="center">
&#x20; \<strong>DAYMARK\</strong>\<br/>
&#x20; Plan your day. Track your progress.
\</p>
