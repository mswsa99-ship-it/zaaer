import { lazy, Suspense } from "react";
import { Routes, Route, Navigate } from "react-router-dom";
import { isDemo } from "./lib/supabase";
import { LoadingScreen } from "./components/ui";
import { useAuth } from "./lib/auth";
import GuestLayout from "./layouts/GuestLayout";
import StaffLayout from "./layouts/StaffLayout";
import AdminLayout from "./layouts/AdminLayout";
import { RequireRole } from "./components/RequireRole";

import Landing from "./pages/guest/Landing";
import BookingLookup from "./pages/guest/BookingLookup";
import BookingNew from "./pages/guest/BookingNew";
import Registration from "./pages/guest/Registration";
import BookingStatus from "./pages/guest/BookingStatus";
import CheckIn from "./pages/guest/CheckIn";
import Kiosk from "./pages/guest/Kiosk";
import Privacy from "./pages/guest/Privacy";
import Terms from "./pages/guest/Terms";

import StaffLogin from "./pages/staff/StaffLogin";
import StaffDashboard from "./pages/staff/StaffDashboard";
import Arrivals from "./pages/staff/Arrivals";
import StaffReservations from "./pages/staff/StaffReservations";
import StaffReservationDetail from "./pages/staff/StaffReservationDetail";
import IdentityVerification from "./pages/staff/IdentityVerification";
import StaffPayments from "./pages/staff/StaffPayments";
import AccessApprovals from "./pages/staff/AccessApprovals";
import StayFollowups from "./pages/staff/StayFollowups";
import DaySummary from "./pages/staff/DaySummary";
import StaffRooms from "./pages/staff/StaffRooms";
import Housekeeping from "./pages/staff/Housekeeping";
import Codes from "./pages/staff/Codes";
import Tickets from "./pages/staff/Tickets";
import Inbox from "./pages/staff/Inbox";

import AdminDashboard from "./pages/admin/AdminDashboard";
import AdminBranches from "./pages/admin/AdminBranches";
import AdminRoomCategories from "./pages/admin/AdminRoomCategories";
import AdminRooms from "./pages/admin/AdminRooms";
import AdminAvailability from "./pages/admin/AdminAvailability";
import AdminAvailabilityRules from "./pages/admin/AdminAvailabilityRules";
import AdminReservations from "./pages/admin/AdminReservations";
import AdminGuests from "./pages/admin/AdminGuests";
import AdminFinance from "./pages/admin/AdminFinance";
import AdminStaff from "./pages/admin/AdminStaff";
import AdminRoles from "./pages/admin/AdminRoles";
import AdminBookingSources from "./pages/admin/AdminBookingSources";
import AdminAiSettings from "./pages/admin/AdminAiSettings";
import AdminWhatsapp from "./pages/admin/AdminWhatsapp";
import AdminPaymentProviders from "./pages/admin/AdminPaymentProviders";
import AdminPolicies from "./pages/admin/AdminPolicies";
import AdminKnowledge from "./pages/admin/AdminKnowledge";
import AdminReports from "./pages/admin/AdminReports";
import AdminAuditLogs from "./pages/admin/AdminAuditLogs";
import AdminIntegrations from "./pages/admin/AdminIntegrations";
import AdminStructure from "./pages/admin/AdminStructure";
import AdminFacilities from "./pages/admin/AdminFacilities";
import AdminTaskTypes from "./pages/admin/AdminTaskTypes";
import AdminServices from "./pages/admin/AdminServices";
import AdminAssistant from "./pages/admin/AdminAssistant";
import AdminDataPurge from "./pages/admin/AdminDataPurge";
import StaffReservationNew from "./pages/staff/StaffReservationNew";
import PosSettlement from "./pages/staff/PosSettlement";
import AdminCashAccounts from "./pages/admin/AdminCashAccounts";
import AdminPlatformPayouts from "./pages/admin/AdminPlatformPayouts";
import AdminRates from "./pages/admin/AdminRates";
/** demo only: the guest's WhatsApp as answered by the reception computer (runs the server's own code on demo data) */
const WhatsAppDemo = isDemo ? lazy(() => import("./pages/guest/WhatsAppDemo")) : null;

function ProtectedStaff({ children }: { children: React.ReactNode }) {
  const { session, loading } = useAuth();
  if (loading) return null;
  if (!session) return <Navigate to="/staff/login" replace />;
  return <>{children}</>;
}

export default function App() {
  return (
    <Routes>
      {/* Guest */}
      <Route element={<GuestLayout />}>
        <Route path="/" element={<Landing />} />
        <Route path="/reception" element={<Landing />} />
        <Route path="/booking/lookup" element={<BookingLookup />} />
        <Route path="/booking/new" element={<BookingNew />} />
        <Route path="/booking/registration/:token" element={<Registration />} />
        <Route path="/booking/status/:token" element={<BookingStatus />} />
        <Route path="/booking/payment/:token" element={<BookingStatus />} />
        <Route path="/checkin/:token" element={<CheckIn />} />
        <Route path="/kiosk" element={<Kiosk />} />
        {WhatsAppDemo && <Route path="/whatsapp-demo" element={<Suspense fallback={<LoadingScreen />}><WhatsAppDemo /></Suspense>} />}
        <Route path="/privacy" element={<Privacy />} />
        <Route path="/terms" element={<Terms />} />
      </Route>

      {/* Staff login (public) */}
      <Route path="/staff/login" element={<StaffLogin />} />

      {/* Staff — session required (ProtectedStaff); role + authorised branch per page (RequireRole, table in lib/nav.ts) */}
      <Route element={<ProtectedStaff><StaffLayout /></ProtectedStaff>}>
        <Route element={<RequireRole />}>
          <Route path="/staff/dashboard" element={<StaffDashboard />} />
          <Route path="/staff/arrivals" element={<Arrivals />} />
          <Route path="/staff/reservations" element={<StaffReservations />} />
          <Route path="/staff/reservations/new" element={<StaffReservationNew />} />
          <Route path="/staff/reservations/:id" element={<StaffReservationDetail />} />
          <Route path="/staff/identity-verification" element={<IdentityVerification />} />
          <Route path="/staff/payments" element={<StaffPayments />} />
          <Route path="/staff/pos-settlement" element={<PosSettlement />} />
          <Route path="/staff/access-approvals" element={<AccessApprovals />} />
          <Route path="/staff/followups" element={<StayFollowups />} />
          <Route path="/staff/day-summary" element={<DaySummary />} />
          <Route path="/staff/rooms" element={<StaffRooms />} />
          <Route path="/staff/housekeeping" element={<Housekeeping />} />
          <Route path="/staff/codes" element={<Codes />} />
          <Route path="/staff/tickets" element={<Tickets />} />
          <Route path="/staff/inbox" element={<Inbox />} />
        </Route>
      </Route>

      {/* Admin */}
      <Route element={<ProtectedStaff><AdminLayout /></ProtectedStaff>}>
        <Route element={<RequireRole />}>
          <Route path="/admin/dashboard" element={<AdminDashboard />} />
          <Route path="/admin/branches" element={<AdminBranches />} />
          <Route path="/admin/room-categories" element={<AdminRoomCategories />} />
          <Route path="/admin/rooms" element={<AdminRooms />} />
          <Route path="/admin/structure" element={<AdminStructure />} />
          <Route path="/admin/facilities" element={<AdminFacilities />} />
          <Route path="/admin/task-types" element={<AdminTaskTypes />} />
          <Route path="/admin/services" element={<AdminServices />} />
          <Route path="/admin/rates" element={<AdminRates />} />
          <Route path="/admin/availability" element={<AdminAvailability />} />
          <Route path="/admin/availability-rules" element={<AdminAvailabilityRules />} />
          <Route path="/admin/reservations" element={<AdminReservations />} />
          <Route path="/admin/guests" element={<AdminGuests />} />
          <Route path="/admin/finance" element={<AdminFinance />} />
          <Route path="/admin/platform-payouts" element={<AdminPlatformPayouts />} />
          <Route path="/admin/cash-accounts" element={<AdminCashAccounts />} />
          {/* the key boxes moved to the one screen «الرموز» */}
          <Route path="/admin/keyboxes" element={<Navigate to="/staff/codes" replace />} />
          <Route path="/admin/staff" element={<AdminStaff />} />
          <Route path="/admin/roles" element={<AdminRoles />} />
          <Route path="/admin/booking-sources" element={<AdminBookingSources />} />
          <Route path="/admin/ai-settings" element={<AdminAiSettings />} />
          <Route path="/admin/whatsapp" element={<AdminWhatsapp />} />
          <Route path="/admin/assistant" element={<AdminAssistant />} />
          <Route path="/admin/data-purge" element={<AdminDataPurge />} />
          <Route path="/admin/payment-providers" element={<AdminPaymentProviders />} />
          <Route path="/admin/policies" element={<AdminPolicies />} />
          <Route path="/admin/knowledge" element={<AdminKnowledge />} />
          <Route path="/admin/reports" element={<AdminReports />} />
          <Route path="/admin/audit-logs" element={<AdminAuditLogs />} />
          <Route path="/admin/integrations" element={<AdminIntegrations />} />
        </Route>
      </Route>

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
