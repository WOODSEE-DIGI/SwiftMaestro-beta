# SwiftMaestro Sources Analysis

## Top 3 Subdirectories by File Count:
1. **Services** - 58 files (business logic, integrations, managers)
2. **Views** - 47 files (UI components and panel views)
3. **ViewModels/Adapters** - Need to check (likely 20-30 files)

## Observation on Code Organization:
The project follows a clear **MVVM-inspired architecture** with strong separation of concerns:
- `Services/` handles all external integrations (Apple APIs, MCP servers, model management)
- `Views/` contains pure SwiftUI views with no business logic
- `Models/` defines data structures and domain types
- `ViewModels/` (implied) would connect Services to Views

This modular structure makes it easy to test services independently and swap UI implementations.