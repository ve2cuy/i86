# ------------------------------------------------
# checksum.ps1
# Calcule et injecte le checksum d'une option ROM
# Usage : .\checksum.ps1 extra_rom.bin
# ------------------------------------------------

param(
    [Parameter(Mandatory=$true)]
    [string]$FileName
)

$path = Join-Path (Get-Location).Path $FileName

if (-not (Test-Path $path)) {
    Write-Host "Erreur : fichier introuvable -> $path" -ForegroundColor Red
    exit 1
}

# Étape 1 : calcul du checksum (somme de tous les octets sauf le dernier)
$bytes = [System.IO.File]::ReadAllBytes($path)
$sum = 0
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    $sum = ($sum + $bytes[$i]) % 256
}
$checksum = (256 - $sum) % 256
Write-Host "Checksum calculé : $checksum (0x$('{0:X2}' -f $checksum))"

# Étape 2 : écriture du checksum dans le dernier octet
$fileBytes = [System.IO.File]::ReadAllBytes($path)
$fileBytes[$fileBytes.Length - 1] = $checksum
[System.IO.File]::WriteAllBytes($path, $fileBytes)

# Étape 3 : vérification finale
$bytes = [System.IO.File]::ReadAllBytes($path)
$total = 0
foreach ($b in $bytes) { $total = ($total + $b) % 256 }

if ($total -eq 0) {
    Write-Host "Checksum injecté avec succès. Somme totale = $total (OK)" -ForegroundColor Green
} else {
    Write-Host "Problème : somme totale = $total (devrait être 0)" -ForegroundColor Red
    exit 1
}