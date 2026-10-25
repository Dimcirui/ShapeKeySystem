<#
从 Lua 源码中去掉注释，供 package.ps1 打包时使用。

  . strip-lua.ps1                              载入 Remove-LuaComments（供 package.ps1 调用）
  strip-lua.ps1 -Source <目录> -Dest <目录>     把目录下全部 .lua 去掉注释后写到另一个目录（离线测试用）

按 Lua 词法切分：短字符串、[[ ]] / [==[ ]==] 长字符串原样保留，-- 行注释和 --[[ ]] 长注释删除。
注释里的换行保留，行尾多出的空白去掉，输出与源码行号一一对应，玩家报错的行号仍能对上仓库。
#>
param([string]$Source, [string]$Dest)

if (-not ("SksLuaStrip" -as [type])) {
    Add-Type -TypeDefinition @'
using System.Text;
public static class SksLuaStrip {
    // level of a long bracket opening at i ("[" "="* "["), or -1
    static int Open(string s, int i) {
        if (i >= s.Length || s[i] != '[') return -1;
        int j = i + 1;
        while (j < s.Length && s[j] == '=') j++;
        return (j < s.Length && s[j] == '[') ? j - i - 1 : -1;
    }
    // index just past the closing "]" "="*level "]" from i, or s.Length when unterminated
    static int Close(string s, int i, int level) {
        string close = "]" + new string('=', level) + "]";
        int k = s.IndexOf(close, i, System.StringComparison.Ordinal);
        return k < 0 ? s.Length : k + close.Length;
    }
    static void Newlines(StringBuilder o, string s, int from, int to) {
        for (int k = from; k < to; k++) if (s[k] == '\r' || s[k] == '\n') o.Append(s[k]);
    }
    public static string Strip(string s) {
        var o = new StringBuilder(s.Length);
        int i = 0, n = s.Length;
        while (i < n) {
            char c = s[i];
            if (c == '-' && i + 1 < n && s[i + 1] == '-') {
                int level = Open(s, i + 2);
                if (level >= 0) {
                    int end = Close(s, i + 2 + level + 2, level);
                    Newlines(o, s, i, end);
                    i = end;
                } else {
                    while (i < n && s[i] != '\r' && s[i] != '\n') i++;
                }
                continue;
            }
            if (c == '[') {
                int level = Open(s, i);
                if (level >= 0) {
                    int end = Close(s, i + level + 2, level);
                    o.Append(s, i, end - i);
                    i = end;
                    continue;
                }
            }
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && s[j] != c && s[j] != '\n') {
                    if (s[j] != '\\' || j + 1 >= n) { j++; continue; }
                    char e = s[j + 1];
                    if (e == 'z') {
                        // \z skips the whitespace after it, line breaks included
                        j += 2;
                        while (j < n && char.IsWhiteSpace(s[j])) j++;
                    } else if (e == '\r' && j + 2 < n && s[j + 2] == '\n') {
                        j += 3;
                    } else {
                        j += 2;
                    }
                }
                if (j < n && s[j] == c) j++;
                o.Append(s, i, j - i);
                i = j;
                continue;
            }
            o.Append(c);
            i++;
        }
        // trailing blanks left where a comment followed code; line breaks are kept as they were
        var lines = o.ToString().Split('\n');
        for (int k = 0; k < lines.Length; k++) {
            string l = lines[k];
            bool cr = l.EndsWith("\r");
            lines[k] = (cr ? l.Substring(0, l.Length - 1) : l).TrimEnd(' ', '\t') + (cr ? "\r" : "");
        }
        return string.Join("\n", lines);
    }
}
'@
}

# UTF-8 bytes of a .lua file with its comments removed; a byte order mark is kept when present
function Remove-LuaComments([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = (New-Object Text.UTF8Encoding $false).GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $out = (New-Object Text.UTF8Encoding $false).GetBytes([SksLuaStrip]::Strip($text))
    if (-not $bom) { return ,$out }
    return ,([byte[]](0xEF, 0xBB, 0xBF) + $out)
}

if ($Source) {
    if (-not $Dest) { throw "-Dest is required with -Source" }
    $root = (Resolve-Path -LiteralPath $Source).Path
    Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.lua | ForEach-Object {
        $target = Join-Path $Dest $_.FullName.Substring($root.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path -Parent $target) | Out-Null
        [IO.File]::WriteAllBytes($target, (Remove-LuaComments $_.FullName))
    }
}
