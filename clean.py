import re
import os

def clean_file(filepath):
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    new_lines = []
    
    # Regex to catch: log_cmd "Some Chinese" "Some English"
    dual_log_regex = re.compile(r'^(\s*)(error|yellow|blue|green|echo)\s+"(?:[^"]*[\u4e00-\u9fa5]+[^"]*)"\s+"([^"]+)"\s*$')
    
    # Regex to catch single Chinese logs which are usually duplicates
    chinese_only_regex = re.compile(r'[\u4e00-\u9fa5]')

    for line in lines:
        # Match dual parameters: e.g. yellow "检测到Mac，设置alias" "macOS detected,setting alias"
        dual_match = dual_log_regex.search(line)
        if dual_match:
            indent = dual_match.group(1)
            cmd = dual_match.group(2)
            eng_str = dual_match.group(3)
            new_lines.append(f'{indent}{cmd} "{eng_str}"\n')
            continue
            
        # Match Chinese comments line
        if line.strip().startswith('#') and chinese_only_regex.search(line):
            continue
            
        # Skip lines with Chinese remaining (like single log lines to be removed if they are duplicates)
        if chinese_only_regex.search(line) and ("error" in line or "echo" in line or "yellow" in line or "blue" in line or "green" in line):
            print(f"Skipping: {line.strip()}")
            continue
            
        new_lines.append(line)

    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)

if __name__ == "__main__":
    target_file = r"functions.sh"
    if os.path.exists(target_file):
        clean_file(target_file)
    else:
        clean_file("functions.sh")