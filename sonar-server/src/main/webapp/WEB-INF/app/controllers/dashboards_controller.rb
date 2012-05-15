#
# Sonar, entreprise quality control tool.
# Copyright (C) 2008-2012 SonarSource
# mailto:contact AT sonarsource DOT com
#
# Sonar is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 3 of the License, or (at your option) any later version.
#
# Sonar is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with Sonar; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02
#
class DashboardsController < ApplicationController

  SECTION=Navigation::SECTION_RESOURCE

  verify :method => :post, :only => [:create, :update, :delete, :up, :down, :follow, :unfollow], :redirect_to => {:action => :index}
  before_filter :login_required

  def index
    @global = !params[:resource]

    @actives=ActiveDashboard.user_dashboards(current_user, @global)
    @shared_dashboards=Dashboard.find(:all, :conditions => ['(user_id<>? OR user_id IS NULL) AND shared=?', current_user.id, true], :order => 'name ASC')
    active_dashboard_ids=@actives.map(&:dashboard_id)
    @shared_dashboards.reject! { |d| active_dashboard_ids.include?(d.id) }
    @shared_dashboards.reject! { |a| a.global != @global}

    if params[:resource]
      @resource=Project.by_key(params[:resource])
      if @resource.nil?
      # TODO display error page
        redirect_to home_path
        return false
      end
      access_denied unless has_role?(:user, @resource)
      @snapshot = @resource.last_snapshot
      @project=@resource # variable name used in old widgets
    end
  end

  def create
    @dashboard=Dashboard.new()
    load_dashboard_from_params(@dashboard)

    active_dashboard = current_user.active_dashboards.to_a.find { |ad| ad.name==@dashboard.name }
    if active_dashboard
      flash[:error]=Api::Utils.message('dashboard.error_create_existing_name')
      redirect_to :controller => 'dashboards', :action => 'index', :resource => params[:resource]
    elsif @dashboard.save
      add_default_dashboards_if_first_user_dashboard
      last_active_dashboard=current_user.active_dashboards.max_by(&:order_index)
      current_user.active_dashboards.create(:dashboard => @dashboard, :user_id => current_user.id, :order_index => (last_active_dashboard ? last_active_dashboard.order_index+1 : 1))
      redirect_to :controller => 'dashboard', :action => 'configure', :did => @dashboard.id, :id => (params[:resource] unless @dashboard.global)
    else
      flash[:error]=@dashboard.errors.full_messages.join('<br/>')
      redirect_to :controller => 'dashboards', :action => 'index', :resource => params[:resource]
    end
  end

  def edit
    @dashboard=Dashboard.find(params[:id])
    if @dashboard.owner?(current_user)
      render :partial => 'edit'
    else
      redirect_to :controller => 'dashboards', :action => 'index', :resource => params[:resource]
    end
  end

  def update
    dashboard=Dashboard.find(params[:id])
    if dashboard.owner?(current_user)
      load_dashboard_from_params(dashboard)

      if dashboard.save
        if !dashboard.shared?
          ActiveDashboard.destroy_all(['dashboard_id = ? and (user_id<>? OR user_id IS NULL)', dashboard.id, current_user.id])
        end
      else
        flash[:error]=dashboard.errors.full_messages.join('<br/>')
      end
    else
      # TODO explicit error
    end
    redirect_to :action => 'index', :resource => params[:resource]
  end

  def delete
    dashboard=Dashboard.find(params[:id])
    bad_request('Unknown dashboard') unless dashboard
    access_denied unless dashboard.owner?(current_user)

    if dashboard.destroy
      flash[:error]=Api::Utils.message('dashboard.default_restored') if ActiveDashboard.count(:conditions => ['user_id=?', current_user.id])==0
    else
      flash[:error]=Api::Utils.message('dashboard.error_delete_default')
    end
    redirect_to :action => 'index', :resource => params[:resource]

  end

  def down
    position(+1)
  end

  def up
    position(-1)
  end

  def follow
    add_default_dashboards_if_first_user_dashboard
    dashboard=Dashboard.find(:first, :conditions => ['shared=? and id=? and (user_id is null or user_id<>?)', true, params[:id].to_i, current_user.id])
    if dashboard
      active_dashboard = current_user.active_dashboards.to_a.find { |ad| ad.name==dashboard.name }
      if active_dashboard
        flash[:error]=Api::Utils.message('dashboard.error_follow_existing_name')
      else
        current_user.active_dashboards.create(:dashboard => dashboard, :user => current_user, :order_index => current_user.active_dashboards.size+1)
      end
    else
      bad_request('Unknown dashboard')
    end
    redirect_to :action => :index, :resource => params[:resource]
  end

  def unfollow
    add_default_dashboards_if_first_user_dashboard

    ActiveDashboard.destroy_all(['user_id=? AND dashboard_id=?', current_user.id, params[:id].to_i])

    if ActiveDashboard.count(:conditions => ['user_id=?', current_user.id])==0
      flash[:notice]=Api::Utils.message('dashboard.default_restored')
    end
    redirect_to :action => :index, :resource => params[:resource]
  end

  private

  def position(offset)
    add_default_dashboards_if_first_user_dashboard

    dashboards=current_user.active_dashboards.to_a

    to_move = dashboards.find { |a| a.id == params[:id].to_i}
    if to_move
      dashboards_same_type=dashboards.select { |a| (a.global? == to_move.global?) }.sort_by(&:order_index)

      index = dashboards_same_type.index(to_move)
      dashboards_same_type[index], dashboards_same_type[index + offset] = dashboards_same_type[index + offset], dashboards_same_type[index]

      dashboards_same_type.each_with_index do |a,i|
        a.order_index=i+1
        a.save
      end
    end

    redirect_to :action => 'index', :resource => params[:resource]
  end

  def load_dashboard_from_params(dashboard)
    dashboard.name=params[:name]
    dashboard.description=params[:description]
    dashboard.is_global=(params[:global].present?)
    dashboard.shared=(params[:shared].present? && is_admin?)
    dashboard.user_id=current_user.id
    dashboard.column_layout=Dashboard::DEFAULT_LAYOUT if !dashboard.column_layout
  end

  def add_default_dashboards_if_first_user_dashboard
    if current_user.active_dashboards.empty?
      defaults=ActiveDashboard.default_dashboards
      defaults.each do |default_active|
        current_user.active_dashboards.create(:dashboard => default_active.dashboard, :user => current_user, :order_index => current_user.active_dashboards.size+1)
      end
    end
  end


end
