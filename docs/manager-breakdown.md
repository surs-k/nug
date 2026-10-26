# Why Manager is easy to use
___


Manager is the phone app. Changes now copies its rules.
Each rule's name comes from `Visual_Requirements.md`.


## What Manager does right
___


| # | What Manager does | Rule | Why it helps |
| --- | --- | --- | --- |
| 1 | One column, never wider than 560px | Scannability, Proximity | your eyes move down, not around |
| 2 | One screen at a time, tabs at the bottom, Settings off to the side | Hub and spoke, Chunking | you only see one thing at once |
| 3 | Everything sits in rounded cards: a dot, a name, a count | Chunking, Similarity | you know what a card is before you read it |
| 4 | Cards fold, and stay how you left them | Progressive disclosure, User control | you choose what is open |
| 5 | A list shows 7 rows, then **Show 5 more** | Miller's law, Hick's law | never a wall of rows |
| 6 | Three text sizes: big title, normal row, small grey line | Visual hierarchy | the important word is the biggest |
| 7 | Each colour means one thing, and colour is rare | Color coding, Von Restorff | red stands out because little else is red |
| 8 | Rows at least 56px tall, buttons 44px | Fitts's law | easy to hit, no squinting |
| 9 | One tip at a time, gone after 3 days, or press ✕ | Progressive onboarding, Fading | it teaches, then gets out of the way |
| 10 | An empty screen says what to do, with one button | No dead ends | you are never stuck |
| 11 | Every size and colour is a token, themes swap them | Design tokens, Theming | it looks the same everywhere |
| 12 | Search and keys for when you know what you want | Command palette, Accelerators | fast, but hidden until wanted |
| 13 | Short messages that go away | Doherty threshold | you see it worked, then it is gone |


## What made Changes hard
___


| Before | Problem it caused |
| --- | --- |
| Three panes side by side: projects, list, details | Cognitive overload, everything at once |
| One long plain list, small gaps | Wall of text, nothing to group by |
| Same size text almost everywhere | No visual hierarchy |
| System theme, colour only on red text | Weak color coding |
| Up to 500 changes listed at once | Information overload |
| Tips, search, branch box, status bar, two buttons always showing | Visual clutter |
| Hidden right-click menu for project actions | Hidden features |


## What Changes does now
___


| Rule | In Changes now |
| --- | --- |
| Hub and spoke | **Projects**, then one project, then one item. **‹ Back** or Escape goes up one step |
| One column | Max 680px wide, centred, like Manager |
| Chunking | Problems in cards by state. Changes in cards by age: last 7 days, last 30 days, older |
| Progressive disclosure | Only the worst card is open. **Fine**, **Details** and **Files and lines** start folded |
| Miller's law | 7 rows per card, then **Show more** |
| Visual hierarchy | Big title, one plain sentence in **What it means for you**, then two buttons |
| Color coding | Red wrong now, amber could not check, green fine, blue built in. Same in every theme |
| Fitts's law | Rows 56px, buttons 40 to 44px |
| Fading | Each tip shows on 3 days, then hides itself |
| No dead ends | Every empty screen has one sentence and one button |
| Theming | **More › Look**: Slate (Manager's), Midnight, Paper (light), and **Larger text** |
| Command palette | **Search** or Ctrl+K finds any project, problem, change, note or action |
| Less clutter | Rare actions moved into **More**. Messages show for a moment, then go |


## Left out on purpose
___


- Swipe gestures, it is a desktop app
- Expert mode and accent colours, feature creep for now
- The bottom tab bar, the three tabs sit under the title instead
