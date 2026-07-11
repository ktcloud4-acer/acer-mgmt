# NetBox 추가 설정. configuration.py 이후에 로드되어 어떤 값이든 override 한다.
# 컨테이너의 /etc/netbox/config/extra.py 로 read-only 마운트된다.
# env 로 노출되지 않는 설정(CSRF, social-auth OIDC)을 여기서 os.environ 값으로 채운다.
import os

# ── 리버스 프록시(Traefik 가 TLS 종단) ────────────────────────────────
# 프록시 뒤에서는 CSRF 신뢰 origin 을 명시해야 로그인/폼 POST 가 동작한다.
_public_url = os.environ.get("NETBOX_PUBLIC_URL", "").rstrip("/")
if _public_url:
    CSRF_TRUSTED_ORIGINS = [_public_url]

# ── SSO: Keycloak OIDC (realm: mgmt) ─────────────────────────────────
# NetBox 는 python-social-auth 로 SSO 를 처리한다. REMOTE_AUTH_BACKEND 에
# social-auth 백엔드를 지정하면 로컬 로그인과 병행해 SSO 버튼이 노출된다.
# (REMOTE_AUTH_ENABLED 는 헤더 기반 원격 인증용이므로 여기서는 켜지 않는다.)
# Keycloak 클라이언트 콜백 URL: https://netbox.<domain>/oauth/complete/oidc/
_oidc_endpoint = os.environ.get("NETBOX_OIDC_ENDPOINT", "")
if _oidc_endpoint:
    REMOTE_AUTH_BACKEND = "social_core.backends.open_id_connect.OpenIdConnectAuth"
    SOCIAL_AUTH_OIDC_OIDC_ENDPOINT = _oidc_endpoint
    SOCIAL_AUTH_OIDC_KEY = os.environ.get("NETBOX_OIDC_CLIENT_ID", "netbox")
    SOCIAL_AUTH_OIDC_SECRET = os.environ.get("NETBOX_OIDC_CLIENT_SECRET", "")
    SOCIAL_AUTH_OIDC_SCOPE = ["profile", "email"]

    _logout_url = os.environ.get("NETBOX_OIDC_LOGOUT_URL", "")
    if _logout_url:
        LOGOUT_REDIRECT_URL = _logout_url

# ── Keycloak 그룹 → NetBox 권한 매핑 ──────────────────────────────────
# Keycloak 그룹은 OIDC userinfo 의 `groups` claim 으로 들어온다. NetBox 4의
# 사용자 모델에는 Django admin용 is_staff 필드가 없으므로, 편집 권한은 NetBox
# 로컬 그룹의 Object Permission으로 관리하고 관리자만 is_superuser로 승격한다.
#
# `platform-admin`은 서비스별 그룹 전환 중 기존 운영자를 끊지 않기 위한 임시
# 호환 관리자 그룹이다. 신규 권한 부여는 netbox-editor/netbox-admin만 사용한다.
_NETBOX_EDITOR_GROUP = "netbox-editor"
_NETBOX_ADMIN_GROUPS = {"netbox-admin", "platform-admin"}


def map_keycloak_groups(response=None, user=None, *args, **kwargs):
    """Synchronize the managed NetBox role and administrator bit at OIDC login."""
    if not user or not isinstance(response, dict):
        return

    # extra.py is imported while Django settings are assembled. Importing the
    # auth model here, after the social-auth pipeline runs, avoids accessing
    # the app registry before it has been initialized.
    from django.contrib.auth.models import Group

    keycloak_groups = {str(group) for group in (response.get("groups") or [])}
    is_admin = bool(_NETBOX_ADMIN_GROUPS.intersection(keycloak_groups))

    if user.is_superuser != is_admin:
        user.is_superuser = is_admin
        user.save(update_fields=["is_superuser"])

    editor_group, _ = Group.objects.get_or_create(name=_NETBOX_EDITOR_GROUP)
    if _NETBOX_EDITOR_GROUP in keycloak_groups:
        user.groups.add(editor_group)
    else:
        user.groups.remove(editor_group)


# This is NetBox 4.5's stock pipeline plus the final local role synchronizer.
# Configuration files are loaded before netbox.settings defines its default,
# therefore importing SOCIAL_AUTH_PIPELINE here would create a circular import.
SOCIAL_AUTH_PIPELINE = (
    "social_core.pipeline.social_auth.social_details",
    "social_core.pipeline.social_auth.social_uid",
    "social_core.pipeline.social_auth.social_user",
    "social_core.pipeline.user.get_username",
    "social_core.pipeline.user.create_user",
    "social_core.pipeline.social_auth.associate_user",
    "netbox.authentication.user_default_groups_handler",
    "social_core.pipeline.social_auth.load_extra_data",
    "social_core.pipeline.user.user_details",
    "extra.map_keycloak_groups",
)

# ── 운영 편의 ────────────────────────────────────────────────────────
BANNER_TOP = "ACER 인프라 Source of Truth (IPAM/CMDB)"
BANNER_LOGIN = "사내 전용. 변경은 GitOps/IaC 경유를 권장합니다."
CENSUS_REPORTING_ENABLED = False
