// ============================================================
// ============================================================
//
//   <script>
//       window.SA_REQUIRED_ROLE = { sessionKey: 'sa_current_student', loginUrl: 'student-login/' };
//   </script>
//   <script src="js/route-guard.js"></script>
//
// (sa_current_student / sa_current_teacher / sa_current_admin /
(function () {
    var role = window.SA_REQUIRED_ROLE;
    if (!role || !role.sessionKey || !role.loginUrl) return;

    function isValidSession(key) {
        var stored = localStorage.getItem(key);
        if (!stored) return false;

        var raw;
        try {
            raw = JSON.parse(stored);
        } catch (e) {
            localStorage.removeItem(key);
            return false;
        }

        if (!raw || !raw.data || !raw.expiresAt || Date.now() > raw.expiresAt) {
            localStorage.removeItem(key);
            return false;
        }

        return true;
    }

    if (!isValidSession(role.sessionKey)) {
        window.location.replace(role.loginUrl);
    }
})();
