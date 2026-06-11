$repoPath = "e:\source\github.com\joelvaneenwyk\mise"
$outFile = Join-Path $repoPath "__git_info_output.txt"

Set-Location $repoPath

$output = @()
$output += "=== GIT STATUS ==="
$output += (git status --porcelain 2>&1)
$output += ""
$output += "=== GIT LOG (last 20) ==="
$output += (git log --oneline -20 2>&1)
$output += ""
$output += "=== GIT BRANCH ==="
$output += (git branch -vv 2>&1)
$output += ""
$output += "=== GIT REMOTE ==="
$output += (git remote -v 2>&1)
$output += ""
$output += "=== GIT DIFF STAT vs origin/main ==="
$output += (git diff --stat origin/main 2>&1)
$output += ""
$output += "=== GIT LOG origin/main..HEAD ==="
$output += (git log --oneline origin/main..HEAD 2>&1)

$output | Out-File -FilePath $outFile -Encoding utf8
Write-Host "Done writing to $outFile"
