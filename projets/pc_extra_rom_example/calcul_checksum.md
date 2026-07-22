## Calcul et injection du checksum à la fin d'un ROM PC Extra

---

```powershell
$path = Join-Path (Get-Location).Path "extra_rom.bin"

# Étape 1 : calcul du checksum
$bytes = [System.IO.File]::ReadAllBytes($path)
$sum = 0
for ($i = 0; $i -lt $bytes.Length - 1; $i++) {
    $sum = ($sum + $bytes[$i]) % 256
}
$checksum = (256 - $sum) % 256
Write-Host "Checksum à écrire : $checksum (0x$('{0:X2}' -f $checksum))"

# Étape 2 : écriture du checksum dans le dernier octet
$fileBytes = [System.IO.File]::ReadAllBytes($path)
$fileBytes[$fileBytes.Length - 1] = $checksum
[System.IO.File]::WriteAllBytes($path, $fileBytes)

# Étape 3 : vérification finale
$bytes = [System.IO.File]::ReadAllBytes($path)
$total = 0
foreach ($b in $bytes) { $total = ($total + $b) % 256 }
Write-Host "Somme totale (doit être 0) : $total"
```