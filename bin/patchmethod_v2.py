import sys
import os
import re

def replace_method_body(smali_path, method_name, new_body):
    with open(smali_path, 'r') as f:
        content = f.read()

    pattern = rf'(\.method[^\n]* {re.escape(method_name)}\(.*?\n)(.*?)(\.end method)'
    match = re.search(pattern, content, re.DOTALL)

    if not match:
        print(f"----> Method '{method_name}' not found in {smali_path}")
        return

    start = match.group(1)
    end = match.group(3)

    new_method = start + new_body.strip() + '\n' + end
    content = re.sub(pattern, new_method, content, flags=re.DOTALL)

    with open(smali_path, 'w') as f:
        f.write(content)

    print(f"----> Replaced body of method '{method_name}' in: {smali_path}")


STUB_METHOD = '''\
    .locals 1
    const/4 v0, 0x%s
    return v0
'''

STUB_VOID = '''\
    .locals 0
    return-void
'''

def patch_method_in_file(smali_path, method_set, return_type="true"):
    if not os.path.isfile(smali_path):
        print(f"----> Ignore patch: \"{os.path.basename(smali_path)}\" not found")
        return

    with open(smali_path, 'r') as f:
        smali = f.read()

    method_name = ''
    patched = ''
    overwriting = False

    if return_type == "true":
        overvalue = '1'
    elif return_type == "false":
        overvalue = '0'
    elif return_type == "void":
        overvalue = '-1'
    else:
        print("Error: Invalid return type specified.")
        return

    for line in smali.splitlines():
        method_line = re.search(r'\.method\s+(?:(?:public|private)\s+)?(?:static\s+)?(?:final\s+)?([^\(]+)\(', line)
        if method_line:
            method_name = method_line.group(1)
            if method_name in method_set:
                overwriting = True
            patched += line + '\n'
        elif '.end method' in line:
            if overwriting:
                overwriting = False
                if overvalue == '-1':
                    patched += STUB_VOID + line + '\n'
                    print(f"----> patched method in {smali_path}: {method_name} => void")
                else:
                    patched += (STUB_METHOD % overvalue) + line + '\n'
                    print(f"----> patched method in {smali_path}: {method_name} => " + ('true' if overvalue == '1' else 'false'))
            else:
                patched += line + '\n'
        else:
            if not overwriting:
                patched += line + '\n'

    with open(smali_path, 'w') as f:
        f.write(patched)

def search_and_hook(smali_dir, keyword_pattern, hook_line_template):
    """
    - 在目录中递归找.smali文件
    - 找方法中包含keyword_pattern的行
    - 找到紧跟的 move-result [vp][数字]行
    - 在move-result行前插入hook_line_template，替换reg占位符为捕获的寄存器名
    """
    keyword_re = re.compile(keyword_pattern)
    move_result_re = re.compile(r'^\s*move-result\s+([vp]\d+)')

    for root, _, files in os.walk(smali_dir):
        for file in files:
            if not file.endswith('.smali'):
                continue
            path = os.path.join(root, file)

            with open(path, 'r', encoding='utf-8') as f:
                lines = f.readlines()

            modified = False
            found_keyword = False
            new_lines = []

            for line in lines:
                if not found_keyword and keyword_re.search(line):
                    found_keyword = True

                # 找到move-result，且之前找到关键字，插入hook
                if found_keyword:
                    m = move_result_re.match(line)
                    if m:
                        reg = m.group(1)
                        # 替换hook中的reg占位符
                        hook_line = hook_line_template.replace('reg', reg)
                        new_lines.append(hook_line + '\n')
                        modified = True
                        found_keyword = False  # reset，避免多次插入
                        continue

                new_lines.append(line)

            if modified:
                with open(path, 'w', encoding='utf-8') as f:
                    f.writelines(new_lines)
                print(f"----> Patched {path}")



def search_and_patch(smali_dir, keywords, return_type="true", method_body=None):
    method_set = set()
    for root, _, files in os.walk(smali_dir):
        for file in files:
            if file.endswith(".smali"):
                smali_path = os.path.join(root, file)
                with open(smali_path, 'r') as f:
                    smali_content = f.read()

                for method_match in re.finditer(r'\.method\s+(?:(?:public|private)\s+)?(?:static\s+)?(?:final\s+)?([^\(]+)\(.*?\.end method', smali_content, re.DOTALL):
                    method_content = method_match.group(0)
                    if all(keyword in method_content for keyword in keywords):
                        method_name = re.search(r'\.method\s+(?:(?:public|private)\s+)?(?:static\s+)?(?:final\s+)?([^\(]+)\(', method_content).group(1)
                        method_set.add(method_name)
                        print(f"Found method '{method_name}' in file: {smali_path}")
                        if method_body:
                            replace_method_body(smali_path, method_name, method_body)
                        else:
                            patch_method_in_file(smali_path, {method_name}, return_type)

def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 patchmethod_v2.py <smali_file> <method_name> [-return true|false|void] [<method_body_string>]")
        print("  Or:")
        print("  python3 patchmethod_v2.py -d <directory> -k <keyword1> [keyword2 ...] [-return true|false|void] [-m <method_body_file>]")
        print("  Or:")
        print("  python3 patchmethod_v2.py -d <directory> -k <keyword_regex> -hook <hook_code_with_reg>")
        return 1

    return_type = "true"
    smali_dir = ""
    keywords = []
    method_body = None

    # ---------------------------
    # hook 模式优先
    if "-d" in sys.argv and "-k" in sys.argv and "-hook" in sys.argv:
        dir_index = sys.argv.index("-d") + 1
        key_index = sys.argv.index("-k") + 1
        hook_index = sys.argv.index("-hook") + 1

        if dir_index >= len(sys.argv) or key_index >= len(sys.argv) or hook_index >= len(sys.argv):
            print("Error: Missing argument for -d, -k or -hook.")
            return 1

        smali_dir = sys.argv[dir_index]
        keyword_pattern = sys.argv[key_index]
        hook_line_template = sys.argv[hook_index]

        search_and_hook(smali_dir, keyword_pattern, hook_line_template)
        return 0

    # ---------------------------
    # 处理 return 类型参数 (-return true|false|void)
    if "-return" in sys.argv:
        return_index = sys.argv.index("-return") + 1
        if return_index < len(sys.argv):
            return_type = sys.argv[return_index]
        else:
            print("Error: Missing return type after -return.")
            return 1

    # ---------------------------
    # 处理方法体文件参数 (-m)
    if "-m" in sys.argv:
        m_index = sys.argv.index("-m") + 1
        if m_index < len(sys.argv):
            method_file = sys.argv[m_index]
            if os.path.isfile(method_file):
                with open(method_file, 'r', encoding='utf-8') as f:
                    method_body = f.read()
            else:
                print(f"Error: Cannot find method body file {method_file}")
                return 1

    # ---------------------------
    # 目录 + 关键词匹配模式
    if "-d" in sys.argv and "-k" in sys.argv:
        dir_index = sys.argv.index("-d") + 1
        if dir_index >= len(sys.argv):
            print("Error: Missing directory after -d.")
            return 1
        smali_dir = sys.argv[dir_index]

        keyword_index = sys.argv.index("-k") + 1
        keywords = []
        i = keyword_index
        while i < len(sys.argv):
            if sys.argv[i] in ("-return", "-m"):
                break
            keywords.append(sys.argv[i])
            i += 1

        if not keywords:
            print("Error: Missing keywords after -k.")
            return 1

        search_and_patch(smali_dir, keywords, return_type, method_body)
        return 0

    # ---------------------------
    # fallback 单文件模式
    smali_path = sys.argv[1]
    if not os.path.isfile(smali_path):
        print(f"Error: Smali file not found: {smali_path}")
        return 1

    method_name = None
    extra_method_body = None
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "-return":
            if i + 1 < len(sys.argv):
                return_type = sys.argv[i + 1]
                i += 2
            else:
                print("Error: Missing return type after -return.")
                return 1
        else:
            if method_name is None:
                method_name = sys.argv[i]
            elif extra_method_body is None:
                extra_method_body = sys.argv[i]
            i += 1

    if method_name is None:
        print("Error: Missing method name")
        return 1

    if extra_method_body:
        # 使用直接提供的方法体字符串替换
        replace_method_body(smali_path, method_name, extra_method_body)
    else:
        # 使用 return_type 生成 stub
        patch_method_in_file(smali_path, {method_name}, return_type)

    return 0


if __name__ == "__main__":
    main()
