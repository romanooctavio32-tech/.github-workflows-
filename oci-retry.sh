#!/usr/bin/env bash
# Reintenta crear una instancia Always Free en Oracle Cloud hasta que haya capacidad.
# Ejecutar en OCI Cloud Shell (ya trae `oci` autenticado).
#
# Uso:
#   export SUBNET_ID="ocid1.subnet.oc1...."      # Redes > VCN-VPS > Subredes > copiar OCID
#   export SSH_PUB_FILE="$HOME/llave.pub"        # clave PUBLICA (.pub), nunca la privada
#   bash oci-retry.sh
#
# Opcionales: SHAPE, OCPUS, MEM_GB, NAME, WAIT_SECONDS
set -u

SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-1}"
MEM_GB="${MEM_GB:-6}"
NAME="${NAME:-vps-ubuntu}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

: "${SUBNET_ID:?Define SUBNET_ID}"
: "${SSH_PUB_FILE:?Define SSH_PUB_FILE}"
[ -f "$SSH_PUB_FILE" ] || { echo "No existe $SSH_PUB_FILE"; exit 1; }

# Compartimento raiz del tenancy (el que usas: "tu-usuario (raiz)")
COMPARTMENT_ID="${COMPARTMENT_ID:-$(oci iam compartment list --all --compartment-id-in-subtree false \
  --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)}"
COMPARTMENT_ID="${COMPARTMENT_ID:-$OCI_TENANCY}"
: "${COMPARTMENT_ID:?No pude detectar el compartimento; exporta COMPARTMENT_ID}"

AD_LIST=$(oci iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
  --query 'data[].name' --raw-output | tr -d '[]," ' | tr '\n' ' ')
echo "Dominios de disponibilidad: $AD_LIST"

# Imagen Ubuntu 24.04 compatible con el shape (aarch64 si es A1)
IMAGE_ID=$(oci compute image list --compartment-id "$COMPARTMENT_ID" \
  --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output)
[ -n "$IMAGE_ID" ] || { echo "No encontre imagen Ubuntu 24.04 para $SHAPE"; exit 1; }
echo "Imagen: $IMAGE_ID"

SHAPE_CFG="{}"
case "$SHAPE" in
  *Flex) SHAPE_CFG="{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM_GB}" ;;
esac

n=0
while true; do
  for AD in $AD_LIST; do
    n=$((n+1))
    echo "[$(date '+%F %T')] Intento $n en $AD ..."
    OUT=$(oci compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD" \
      --shape "$SHAPE" --shape-config "$SHAPE_CFG" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip true \
      --display-name "$NAME" \
      --ssh-authorized-keys-file "$SSH_PUB_FILE" 2>&1)
    if echo "$OUT" | grep -q '"lifecycle-state"'; then
      echo "Instancia creada:"
      echo "$OUT" | grep -E '"id"|"lifecycle-state"|"display-name"'
      echo "Mira la IP publica en Compute > Instancias > $NAME."
      exit 0
    fi
    if echo "$OUT" | grep -qiE 'capacity|InternalError|TooManyRequests'; then
      echo "  Sin capacidad todavia."
    else
      echo "  Error distinto, revisalo:"; echo "$OUT" | tail -n 8
      exit 1
    fi
  done
  sleep "$WAIT_SECONDS"
done
