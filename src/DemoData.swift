import Foundation

// Fictional agents, prompts and one session for `herdr-island --demo`, so README screenshots
// never show a real workspace, file or conversation. Text follows the current language.

enum DemoData {
    static let blockedPane = "demo:p1"
    static let donePane = "demo:p2"
    static let workingPane = "demo:p3"
    static let questionPane = "demo:p4"
    static let idlePane = "demo:p5"
    static let architecturePath = "/Users/you/code/shop-web/docs/ARCHITECTURE.md"

    static func agent(_ pane: String, kind: String, status: String, title: String, workspace: String, tab: String) -> Agent {
        Agent(json: [
            "pane_id": pane, "agent": kind, "agent_status": status, "terminal_title": title,
            "workspace_id": workspace, "tab_id": tab, "cwd": "/Users/you/code/\(workspace)",
            "agent_session": ["value": "demo-\(pane)"],
        ])!
    }

    static var workspaces: [String: String] { ["shop-web": "shop-web", "api": "api-server", "docs": "docs"] }

    static var tabs: [String: String] {
        ["t1": L("checkout", "결제"), "t2": "auth", "t3": L("release", "릴리스"), "t4": L("cart", "장바구니"), "t5": "infra"]
    }

    /// The main island: a permission prompt, a finished agent, two working ones, one idle.
    static func store() -> AgentStore {
        let store = AgentStore(client: HerdrClient(socketPath: "/nonexistent"))
        let now = Date()
        store.loadPreview(agent(blockedPane, kind: "claude", status: "blocked",
                                title: L("Refactor the checkout flow", "결제 흐름 리팩터링"), workspace: "shop-web", tab: "t1"),
                          prompt: PromptParser.parse(permissionScreen), since: now.addingTimeInterval(-24))
        store.loadPreview(agent(donePane, kind: "codex", status: "done",
                                title: L("Add rate limiting to /login", "/login에 요청 제한 추가"), workspace: "api", tab: "t2"),
                          prompt: nil, since: now.addingTimeInterval(-160))
        store.loadPreview(agent(workingPane, kind: "claude", status: "working",
                                title: L("Move cart state to a hook", "장바구니 상태를 훅으로 옮기기"), workspace: "shop-web", tab: "t4"),
                          prompt: nil)
        store.loadPreview(agent("demo:p6", kind: "gemini", status: "working",
                                title: L("Draft the 2.4 release notes", "2.4 릴리스 노트 초안"), workspace: "docs", tab: "t3"),
                          prompt: nil)
        store.loadPreview(agent(idlePane, kind: "cursor", status: "idle", title: L("Terraform cleanup", "Terraform 정리"),
                                workspace: "api", tab: "t5"), prompt: nil)
        store.loadPreviewLabels(workspaces: workspaces, tabs: tabs)
        return store
    }

    /// A store holding just one agent with a multi-question AskUserQuestion.
    static func questionStore() -> AgentStore {
        let store = AgentStore(client: HerdrClient(socketPath: "/nonexistent"))
        store.loadPreview(agent(questionPane, kind: "claude", status: "blocked",
                                title: L("Plan the cart rewrite", "장바구니 재작성 계획"), workspace: "shop-web", tab: "t4"),
                          prompt: PromptParser.parse(questionScreen), since: Date().addingTimeInterval(-8))
        store.loadPreviewLabels(workspaces: workspaces, tabs: tabs)
        return store
    }

    static var permissionScreen: String {
        """
        ────────────────────────────────────────────────
         Bash command
         \(L("Run the checkout test suite", "결제 테스트 묶음 실행"))
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         pnpm test --filter checkout -- --coverage
        ╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don’t ask again for: pnpm test
           3. No
         Esc to cancel · Tab to amend
        """
    }

    static var questionScreen: String {
        """
        ────────────────────────────────────────────────
        ←  ☒ Scope  ☐ State  ☐ Tests  ✔ Submit  →
        \(L("Where should the cart state live?", "장바구니 상태는 어디에 둘까요?"))
        ❯ 1. Zustand
             \(L("Small store, no providers, easy to test.", "작은 스토어, Provider 불필요, 테스트가 쉬워요."))
          2. Redux Toolkit
             \(L("Matches the admin app and its devtools.", "관리자 앱과 같은 방식이고 devtools를 쓸 수 있어요."))
          3. React Context
             \(L("No new dependency; fine for a few values.", "의존성 추가 없음. 값이 적을 때 충분해요."))
          4. Type something.
        ────────────────────────────────────────────────
          5. Chat about this
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
    }

    static var architecture: String {
        L("""
        # Shop Web architecture

        The storefront is a Next.js app. This page explains how state flows
        from the API to the components that render the cart and checkout.

        ## Data layer

        - `api/` wraps every backend call and returns typed results.
        - Responses are cached per request and invalidated on mutation.
        - Errors are mapped to `AppError` before they reach the UI.

        ## Cart state

        Cart state used to live in a React context with a reducer. It is moving
        to a small hook, `useCart`, backed by a store so that checkout, the mini
        cart and the header badge read the same source.

        1. `useCart()` exposes `items`, `total` and `add/remove/clear`.
        2. Totals are derived, never stored.
        3. Persisted to `localStorage` under `shop.cart.v2`.

        > Keep the old context exported until every screen has moved.

        ## Checkout

        Checkout reads the cart once, validates stock, then creates an order.
        Payment is handled by the provider SDK; we only keep the order id.

        ## Testing

        - Unit tests live next to the code (`*.test.ts`).
        - `pnpm test --filter checkout` runs the checkout suite.
        """, """
        # Shop Web 구조

        스토어프론트는 Next.js 앱입니다. 이 문서는 API에서 받은 데이터가
        장바구니와 결제 화면의 컴포넌트까지 어떻게 흐르는지 설명합니다.

        ## 데이터 계층

        - `api/`가 모든 백엔드 호출을 감싸고 타입이 있는 결과를 돌려줍니다.
        - 응답은 요청 단위로 캐시하고, 변경 요청이 오면 무효화합니다.
        - 오류는 UI에 닿기 전에 `AppError`로 바꿉니다.

        ## 장바구니 상태

        장바구니 상태는 reducer가 붙은 React context에 있었습니다. 이제 스토어를
        쓰는 작은 훅 `useCart`로 옮겨서, 결제 화면과 미니 장바구니, 헤더 배지가
        같은 값을 읽게 합니다.

        1. `useCart()`는 `items`, `total`, `add/remove/clear`를 제공합니다.
        2. 합계는 저장하지 않고 계산합니다.
        3. `localStorage`의 `shop.cart.v2`에 저장합니다.

        > 모든 화면이 옮겨질 때까지 기존 context도 export해 둡니다.

        ## 결제

        결제는 장바구니를 한 번 읽고 재고를 확인한 뒤 주문을 만듭니다.
        결제는 결제사 SDK가 처리하고, 우리는 주문 ID만 보관합니다.

        ## 테스트

        - 단위 테스트는 코드 옆에 둡니다(`*.test.ts`).
        - `pnpm test --filter checkout`으로 결제 테스트를 실행합니다.
        """)
    }

    // MARK: - Session

    /// A plausible Claude Code session, written as transcript lines and run through the real parser.
    static func session() -> SessionDetail {
        FileTextLoader.previewFiles[architecturePath] = architecture
        var parser = ClaudeTranscriptParser()
        var clock = Date().addingTimeInterval(-41 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ seconds: Double) -> String {
            clock = clock.addingTimeInterval(seconds)
            return formatter.string(from: clock)
        }
        var message = 0
        func assistant(_ content: [JSON], after seconds: Double, cacheRead: Int, cacheWrite: Int, output: Int) {
            message += 1
            // Model turns take minutes in a real session; tool results stay at their real speed.
            feed(&parser, ["type": "assistant", "timestamp": stamp(seconds * 30), "message": [
                "id": "msg_\(message)", "model": "claude-opus-5-5", "content": content,
                "usage": ["input_tokens": 6, "cache_read_input_tokens": cacheRead,
                          "cache_creation_input_tokens": cacheWrite, "output_tokens": output],
            ]])
        }
        func result(_ id: String, _ text: String, extra: JSON? = nil, after seconds: Double) {
            var line: JSON = ["type": "user", "timestamp": stamp(seconds),
                              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": text]]]]
            if let extra = extra { line["toolUseResult"] = extra }
            feed(&parser, line)
        }
        func tool(_ id: String, _ name: String, _ input: JSON) -> [JSON] { [["type": "tool_use", "id": id, "name": name, "input": input]] }

        feed(&parser, ["type": "user", "timestamp": stamp(0),
                       "message": ["role": "user", "content": L("Move cart state into a useCart hook and keep checkout green.",
                                                                "장바구니 상태를 useCart 훅으로 옮기고 결제 테스트는 계속 통과하게 해줘.")]])
        assistant(tool("todo", "TodoWrite", ["todos": [
            ["content": L("Read the architecture notes", "구조 문서 읽기"), "status": "completed", "activeForm": L("Reading the notes", "문서 읽는 중")],
            ["content": L("Write useCart", "useCart 작성"), "status": "completed", "activeForm": L("Writing useCart", "useCart 작성 중")],
            ["content": L("Switch checkout to the hook", "결제 화면을 훅으로 전환"), "status": "in_progress",
             "activeForm": L("Switching checkout to the hook", "결제 화면을 훅으로 전환하는 중")],
            ["content": L("Run the checkout tests", "결제 테스트 실행"), "status": "pending", "activeForm": L("Running tests", "테스트 실행 중")],
        ]]), after: 6, cacheRead: 38_000, cacheWrite: 21_000, output: 420)
        result("todo", "Todos have been modified successfully.", after: 0.1)
        let excerpt = architecture.components(separatedBy: "\n")[11..<21].joined(separator: "\n")
        assistant(tool("read", "Read", ["file_path": architecturePath, "offset": 12, "limit": 10]),
                  after: 9, cacheRead: 59_000, cacheWrite: 3_200, output: 160)
        result("read", excerpt, extra: ["type": "text", "file": ["filePath": architecturePath, "content": excerpt,
                                                                 "numLines": 10, "startLine": 12, "totalLines": 38]], after: 0.2)
        assistant(tool("grep", "Grep", ["pattern": "CartContext", "path": "src", "output_mode": "content"]),
                  after: 7, cacheRead: 63_000, cacheWrite: 1_800, output: 120)
        result("grep", "src/cart/CartContext.tsx:4:export const CartContext = createContext(null)\n"
               + "src/checkout/Summary.tsx:12:  const { items, total } = useContext(CartContext)\n"
               + "src/layout/HeaderBadge.tsx:7:  const { items } = useContext(CartContext)", after: 0.4)
        let hook = """
        import { create } from "zustand"
        import { persist } from "zustand/middleware"

        type Item = { id: string; price: number; quantity: number }

        type CartState = {
          items: Item[]
          add: (item: Item) => void
          remove: (id: string) => void
          clear: () => void
        }

        export const useCartStore = create<CartState>()(
          persist(
            (set) => ({
              items: [],
              add: (item) => set((s) => ({ items: [...s.items, item] })),
              remove: (id) => set((s) => ({ items: s.items.filter((i) => i.id !== id) })),
              clear: () => set({ items: [] }),
            }),
            { name: "shop.cart.v2" }
          )
        )

        export function useCart() {
          const state = useCartStore()
          const total = state.items.reduce((sum, i) => sum + i.price * i.quantity, 0)
          return { ...state, total }
        }
        """
        assistant(tool("write", "Write", ["file_path": "/Users/you/code/shop-web/src/cart/useCart.ts", "content": hook]),
                  after: 26, cacheRead: 68_000, cacheWrite: 6_400, output: 1_900)
        result("write", "File created successfully", after: 0.3)
        assistant(tool("test", "Bash", ["command": "pnpm test --filter checkout", "description": L("Run the checkout tests", "결제 테스트 실행")]),
                  after: 11, cacheRead: 74_000, cacheWrite: 2_100, output: 90)
        result("test", """
        > shop-web@2.4.0 test
        > vitest run --filter checkout

         ✓ src/checkout/Summary.test.tsx (6 tests) 41ms
         ✓ src/checkout/Payment.test.tsx (9 tests) 77ms
         ✓ src/cart/useCart.test.ts (12 tests) 18ms

         Test Files  3 passed (3)
              Tests  27 passed (27)
           Duration  1.42s
        """, after: 3.1)
        assistant(tool("edit", "Edit", [
            "file_path": "/Users/you/code/shop-web/src/checkout/Summary.tsx",
            "old_string": "  const { items, total } = useContext(CartContext)",
            "new_string": "  const { items, total, remove } = useCart()",
        ]), after: 14, cacheRead: 79_000, cacheWrite: 2_600, output: 340)
        result("edit", "The file has been updated.", extra: ["structuredPatch": [[
            "oldStart": 9, "oldLines": 7, "newStart": 9, "newLines": 8,
            "lines": [
                " import { formatPrice } from \"../lib/money\"",
                "-import { CartContext } from \"../cart/CartContext\"",
                "+import { useCart } from \"../cart/useCart\"",
                " ",
                " export function Summary() {",
                "-  const { items, total } = useContext(CartContext)",
                "+  const { items, total, remove } = useCart()",
                "+  const isEmpty = items.length === 0",
                " ",
                "   return (",
            ],
        ]]], after: 0.3)
        feed(&parser, ["type": "system", "subtype": "turn_duration", "durationMs": 1_712_000, "timestamp": stamp(1)])
        return parser.detail
    }

    private static func feed(_ parser: inout ClaudeTranscriptParser, _ object: JSON) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
        parser.consume(line)
    }
}
