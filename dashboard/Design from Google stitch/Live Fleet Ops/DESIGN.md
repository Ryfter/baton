---
name: Obsidian Command
colors:
  surface: '#131313'
  surface-dim: '#131313'
  surface-bright: '#3a3939'
  surface-container-lowest: '#0e0e0e'
  surface-container-low: '#1c1b1b'
  surface-container: '#201f1f'
  surface-container-high: '#2a2a2a'
  surface-container-highest: '#353534'
  on-surface: '#e5e2e1'
  on-surface-variant: '#c2caad'
  inverse-surface: '#e5e2e1'
  inverse-on-surface: '#313030'
  outline: '#8c9479'
  outline-variant: '#434933'
  surface-tint: '#a0d800'
  primary: '#ffffff'
  on-primary: '#253600'
  primary-container: '#b7f700'
  on-primary-container: '#506e00'
  inverse-primary: '#4b6700'
  secondary: '#e9b3ff'
  on-secondary: '#510074'
  secondary-container: '#7d01b1'
  on-secondary-container: '#e5a9ff'
  tertiary: '#ffffff'
  on-tertiary: '#003064'
  tertiary-container: '#d6e3ff'
  on-tertiary-container: '#0063c3'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#b7f700'
  primary-fixed-dim: '#a0d800'
  on-primary-fixed: '#141f00'
  on-primary-fixed-variant: '#374e00'
  secondary-fixed: '#f6d9ff'
  secondary-fixed-dim: '#e9b3ff'
  on-secondary-fixed: '#310048'
  on-secondary-fixed-variant: '#7200a3'
  tertiary-fixed: '#d6e3ff'
  tertiary-fixed-dim: '#aac7ff'
  on-tertiary-fixed: '#001b3e'
  on-tertiary-fixed-variant: '#00468d'
  background: '#131313'
  on-background: '#e5e2e1'
  surface-variant: '#353534'
typography:
  display-lg:
    fontFamily: Hanken Grotesk
    fontSize: 48px
    fontWeight: '800'
    lineHeight: '1.1'
    letterSpacing: -0.04em
  headline-md:
    fontFamily: Hanken Grotesk
    fontSize: 24px
    fontWeight: '600'
    lineHeight: '1.2'
    letterSpacing: -0.02em
  body-base:
    fontFamily: Hanken Grotesk
    fontSize: 15px
    fontWeight: '400'
    lineHeight: '1.5'
    letterSpacing: 0em
  label-caps:
    fontFamily: JetBrains Mono
    fontSize: 11px
    fontWeight: '700'
    lineHeight: 16px
    letterSpacing: 0.1em
  mono-reasoning:
    fontFamily: JetBrains Mono
    fontSize: 13px
    fontWeight: '400'
    lineHeight: '1.6'
    letterSpacing: 0em
  data-table:
    fontFamily: JetBrains Mono
    fontSize: 12px
    fontWeight: '500'
    lineHeight: '1.4'
    letterSpacing: -0.01em
  headline-md-mobile:
    fontFamily: Hanken Grotesk
    fontSize: 20px
    fontWeight: '600'
    lineHeight: '1.2'
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  unit: 4px
  gutter: 16px
  margin-mobile: 16px
  margin-desktop: 32px
  container-max: 1440px
---

## Brand & Style

This design system is engineered for the high-stakes environment of AI orchestration. It shifts away from passive monitoring toward active "steering," evoking the precision and urgency of a modern aircraft cockpit. The brand personality is technical, authoritative, and energetic, designed for power users who manage complex, multi-agent workflows.

The visual style is **Functional Minimalism mixed with High-Contrast Signal**. It utilizes a deep, multi-layered obsidian foundation to eliminate visual noise, allowing vibrant "signal" colors to cut through the interface. This ensures that the user's attention is immediately drawn to status changes, decision requirements, and live data streams. The aesthetic is unashamedly technical, celebrating the "under-the-hood" nature of agent reasoning through clear typographic hierarchies and high-density information layouts.

## Colors

The palette is optimized for long-duration focus in low-light environments. 

- **The Foundation**: We use a true obsidian background (`#050505`) with charcoal surfaces (`#121212`) to create a sense of infinite depth.
- **Signal Colors**: 
    - **Acid Green (Primary)**: Reserved for "Live" status, active execution, and positive delta values. It represents the "Go" state.
    - **Electric Purple (Secondary)**: Specifically for "Decision Needed" or "Human-in-the-loop" interventions. It is a high-priority interrupt color.
    - **Neon Cyan (Tertiary)**: Used for data visualization, links, and "steering" controls that adjust agent parameters.
- **Neutrality**: Text and icons primarily use varied shades of gray to maintain hierarchy, with white reserved only for the most critical labels.

## Typography

The typography system relies on a sharp distinction between human-centric UI and machine-centric data.

- **Hanken Grotesk**: Used for all structural navigation, headlines, and instructional text. It is a modern, high-legibility sans-serif that feels professional and contemporary.
- **JetBrains Mono**: Used for all agent "reasoning" logs, terminal outputs, and data tables. This monospaced font reinforces the technical "pro-tool" vibe and ensures that columns of numbers and code remain perfectly aligned for quick scanning.

**Hierarchy Strategy**:
- Use **Label-Caps** (JetBrains Mono) for all section headers and status indicators to give them a "military-spec" appearance.
- Use **Mono-Reasoning** for agent activity feeds, providing a distinct visual container for AI-generated thought processes.

## Layout & Spacing

The layout follows a **High-Density Fluid Grid** model. In a "Cockpit" UI, information density is a feature, not a bug.

- **Grid**: A 12-column system on desktop, collapsing to 4 columns on mobile. Gutters are kept tight (16px) to maximize screen real estate.
- **Density**: Use a 4px base unit. Components should favor internal padding over external margins to keep related controls tightly grouped.
- **The Dashboard Model**: Primary "Steering" controls (parameters, toggles) should reside in a fixed-width sidebar (280px), while the "Activity Feed" and "Orchestration Map" occupy the fluid center.
- **Reflow**: On mobile, status cards stack vertically, but the "Live Activity" feed remains pinned to the bottom of the viewport for constant visibility.

## Elevation & Depth

In this obsidian-based system, depth is conveyed through **Tonal Tiering** and **Luminescent Strokes** rather than shadows.

- **Level 0 (Base)**: `#050505` - The main background.
- **Level 1 (Cards/Panels)**: `#121212` - Used for primary content containers. 
- **Level 2 (Inlays/Modals)**: `#1C1C1E` - Used for input areas or nested information within cards.
- **Luminescence**: Elevated elements do not use shadows. Instead, they use a subtle 1px inner stroke (`rgba(255, 255, 255, 0.08)`) to define edges. 
- **Active State**: Active cards or focused inputs receive a primary "Acid Green" or "Electric Purple" outer glow (2px blur) to indicate the "Live" focus area.

## Shapes

The shape language is **Technical and Precise**. We avoid overly bubbly or rounded corners to maintain the professional, "pro-tool" aesthetic.

- **Standard Radius**: 4px (`rounded-sm`) for most cards and input fields.
- **Buttons**: 4px radius for standard actions.
- **Status Indicators**: Status "pills" use a 2px radius or are completely square to feel more like industrial labels.
- **Interactive Elements**: Hover states should be hard-edged or very subtly rounded to mimic the feel of physical hardware buttons in a cockpit.

## Components

- **High-Density Cards**: Cards should omit titles where possible, using **Label-Caps** tags in the top-left corner instead. Key metrics (e.g., Token Usage, Latency) should be displayed in the top-right in JetBrains Mono.
- **Status Indicators**:
    - **Live**: Pulsing Acid Green dot next to JetBrains Mono "LIVE" text.
    - **Parked**: Static charcoal dot with "PARKED" text.
    - **Decision Needed**: Solid Electric Purple block with white "ACTION REQUIRED" text.
- **Steering Controls**: Sliders and toggles should use high-contrast fills. When a user adjusts a parameter, the track should light up in Neon Cyan.
- **Plain English Activity Feeds**: Agent logs should be structured as: `[Timestamp] [Agent Name] > [Action Verb in Cyan] [Object]`. Example: `14:02:01 Researcher > Browsing github.com/repo`.
- **Primary Buttons**: Solid Acid Green with Black text for the "Commit" or "Deploy" actions. 
- **Secondary/Ghost Buttons**: Obsidian background with a thin charcoal border and white text for "Cancel" or "Archive".
- **Inputs**: Dark charcoal background with a Neon Cyan bottom-border that illuminates when focused.