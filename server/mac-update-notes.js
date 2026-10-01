// Native AppKit text editing avoids PowerShell's terminal line editor and preserves pasted newlines.
// Launched by admin.ps1 with a private result-file path. No network or publication occurs here.
ObjC.import('AppKit');

function run(argv) {
    if (argv.length !== 1) throw new Error('Expected a result-file path');
    const app = $.NSApplication.sharedApplication;
    app.setActivationPolicy($.NSApplicationActivationPolicyRegular);

    // Standard responder-chain actions enable Command-V/C/X/A/Z inside NSTextView.
    const menu = $.NSMenu.alloc.init;
    const editItem = $.NSMenuItem.alloc.initWithTitleActionKeyEquivalent('编辑', null, '');
    const editMenu = $.NSMenu.alloc.initWithTitle('编辑');
    [['撤销', 'undo:', 'z'], ['剪切', 'cut:', 'x'], ['复制', 'copy:', 'c'],
        ['粘贴', 'paste:', 'v'], ['全选', 'selectAll:', 'a']].forEach(function (item) {
        editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent(item[0], item[1], item[2]));
    });
    editItem.submenu = editMenu;
    menu.addItem(editItem);
    app.mainMenu = menu;

    const scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 0, 580, 300));
    scroll.hasVerticalScroller = true;
    scroll.borderType = $.NSBezelBorder;
    const editor = $.NSTextView.alloc.initWithFrame($.NSMakeRect(0, 0, 560, 300));
    editor.richText = false;
    editor.allowsUndo = true;
    editor.font = $.NSFont.systemFontOfSize(14);
    editor.textContainerInset = $.NSMakeSize(10, 10);
    editor.verticallyResizable = true;
    editor.horizontallyResizable = false;
    editor.autoresizingMask = $.NSViewWidthSizable;
    editor.textContainer.containerSize = $.NSMakeSize(560, 10000000);
    editor.textContainer.widthTracksTextView = true;
    editor.automaticQuoteSubstitutionEnabled = false;
    editor.automaticDashSubstitutionEnabled = false;
    editor.automaticTextReplacementEnabled = false;
    scroll.documentView = editor;

    const alert = $.NSAlert.alloc.init;
    alert.messageText = '更新说明';
    alert.informativeText = '可直接输入中文或粘贴多行内容，回车换行。可留空。\n点“继续”后返回终端选择更新策略。';
    alert.accessoryView = scroll;
    const next = alert.addButtonWithTitle('继续');
    const cancel = alert.addButtonWithTitle('取消');
    alert.layout;
    // Return belongs to text editing (including IME confirmation), never to form submission.
    next.keyEquivalent = '';
    cancel.keyEquivalent = '\u001b';
    alert.window.title = 'ZTransfer 更新说明';
    alert.window.initialFirstResponder = editor;
    alert.window.makeFirstResponder(editor);
    app.activateIgnoringOtherApps(true);
    const accepted = alert.runModal === $.NSAlertFirstButtonReturn;
    const result = JSON.stringify({ accepted: accepted, text: accepted ? ObjC.unwrap(editor.string) : '' });
    if (!$(result).writeToFileAtomicallyEncodingError(argv[0], true, $.NSUTF8StringEncoding, null)) {
        throw new Error('Unable to save release notes');
    }
}
